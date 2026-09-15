import XCTest
@testable import ForensicLens
import ImageDecoding
import Foundation

final class DoubleCompressionAnalyzerTests: XCTestCase {
    /// A block-independent synthetic image with natural-photo-like DCT
    /// coefficient statistics: energy concentrated near zero and falling
    /// off at higher frequencies, like a real photograph, but with each 8x8
    /// block generated from its own independent random draw so nothing
    /// about the image's own content is spatially periodic. That matters
    /// here specifically because a genuinely periodic *source* image (a
    /// gradient, a repeating texture) would trip this analyzer's histogram
    /// periodicity check all by itself, single-compressed or not -- this
    /// fixture is built to rule that out as an explanation for whatever the
    /// tests below observe.
    private func naturalTextureBuffer(width: Int, height: Int, seed: UInt64) throws -> PixelBuffer {
        var generator = Fixtures.SeededGenerator(seed: seed)
        func uniform01() -> Double { Double(generator.next() >> 11) / Double(1 << 53) }
        func standardNormal() -> Double {
            let u1 = max(uniform01(), 1e-12)
            let u2 = uniform01()
            return (-2 * Foundation.log(u1)).squareRoot() * cos(2 * Double.pi * u2)
        }

        var pixels = [UInt8](repeating: 0, count: width * height)
        var by = 0
        while by < height {
            let blockHeight = min(8, height - by)
            var bx = 0
            while bx < width {
                let blockWidth = min(8, width - bx)

                var coefficients = [Double](repeating: 0, count: 64)
                coefficients[0] = 128 + standardNormal() * 20 // DC: per-block brightness
                for v in 0..<8 {
                    for u in 0..<8 {
                        guard u != 0 || v != 0 else { continue }
                        // Natural images concentrate DCT energy at low
                        // frequencies; this falloff mimics that instead of
                        // handing every frequency equal (white-noise-like)
                        // energy, which would spread coefficient (1,1)'s
                        // value too widely for its histogram to show
                        // anything but sampling noise.
                        let frequency = Double(u + v)
                        let std = 40.0 / (1.0 + frequency * frequency)
                        coefficients[v * 8 + u] = standardNormal() * std
                    }
                }

                let block = DCT8x8.inverse(coefficients)
                for y in 0..<blockHeight {
                    for x in 0..<blockWidth {
                        pixels[(by + y) * width + (bx + x)] = UInt8(clamping: Int(block[y * 8 + x].rounded()))
                    }
                }
                bx += 8
            }
            by += 8
        }
        return try PixelBuffer(width: width, height: height, channels: 1, pixels: pixels)
    }

    /// Simulates one JPEG-style compression pass the same way `ELAAnalyzer`
    /// does: a block DCT, quantize at `quality`, dequantize, inverse DCT.
    /// This package has no real JPEG encoder to round-trip through (see
    /// `ImageDecoder`'s doc comment), so this is the same substitute ELA
    /// already relies on -- applying it twice at different qualities is a
    /// faithful simulation of "saved once, edited, saved again."
    private func compressed(_ buffer: PixelBuffer, quality: Int) -> PixelBuffer {
        JPEGRecompressionSimulator.recompress(buffer, quality: quality)
    }

    private func jpegImage(_ buffer: PixelBuffer) -> ImageData {
        ImageData(rawBytes: [0xFF, 0xD8, 0xFF, 0xD9], pixels: buffer, format: .jpeg)
    }

    /// The specific quality pair used by `testDoubleCompressionIsFlagged`.
    /// Empirically, a *second* pass at a distinctly lower quality than the
    /// first is the case classical double-JPEG-compression detection is
    /// best at (the coarser final quantization step leaves the clearest
    /// trace of the finer first one); a small-integer ratio between the two
    /// passes' quantization steps (quality 60 and quality 40 land on
    /// steps 10 and 15 -- a clean 2:3) produces a much stronger, more
    /// reliable periodicity signal in this histogram-based test than an
    /// arbitrarily-chosen pair does. This was verified empirically across
    /// several random seeds before being fixed here; see
    /// `DCTPeriodicityAnalysis.periodicityStrength`'s doc comment for why
    /// the underlying signal exists at all.
    private static let firstPassQuality = 60
    private static let secondPassQuality = 40

    func testSingleCompressionIsNotFlagged() throws {
        let base = try naturalTextureBuffer(width: 512, height: 512, seed: 7)
        let image = jpegImage(compressed(base, quality: Self.secondPassQuality))

        let finding = try DoubleCompressionAnalyzer().analyze(image, config: .default)

        XCTAssertEqual(finding.score, 0, "a single compression pass should not read as periodic double-compression evidence")
        XCTAssertTrue(finding.indicators.isEmpty)
    }

    func testDoubleCompressionIsFlagged() throws {
        let base = try naturalTextureBuffer(width: 512, height: 512, seed: 7)
        let firstPass = compressed(base, quality: Self.firstPassQuality)
        let secondPass = compressed(firstPass, quality: Self.secondPassQuality)
        let image = jpegImage(secondPass)

        let finding = try DoubleCompressionAnalyzer().analyze(image, config: .default)

        XCTAssertGreaterThan(finding.score, 0, "two compression passes at different qualities should trip the periodicity check")
        XCTAssertFalse(finding.indicators.isEmpty)
        XCTAssertTrue(
            finding.indicators.contains { $0.message.contains("periodic") },
            "expected an indicator describing the periodic DCT coefficient pattern, got: \(finding.indicators.map(\.message))"
        )
    }

    func testNonJPEGInputReportsNotApplicable() throws {
        let buffer = try Fixtures.uniformBuffer(width: 32, height: 32)
        let image = try Fixtures.imageData(from: buffer) // round-trips through PPM, so image.format == .ppm

        let finding = try DoubleCompressionAnalyzer().analyze(image, config: .default)

        XCTAssertEqual(finding.score, 0)
        XCTAssertTrue(finding.indicators.isEmpty)
        XCTAssertTrue(
            finding.summary.contains("PPM") && finding.summary.contains("not applicable"),
            "expected a not-applicable summary naming the non-JPEG format, got: \(finding.summary)"
        )
    }

    func testThrowsUnsupportedInputWhenPixelsAreUnavailable() throws {
        let jpegBytes = Fixtures.jpegBytesWithNoExif()
        let image = try ImageData.load(jpegBytes)
        XCTAssertNil(image.pixels)

        XCTAssertThrowsError(try DoubleCompressionAnalyzer().analyze(image, config: .default)) { error in
            guard case AnalyzerError.unsupportedInput(_) = error else {
                return XCTFail("Expected AnalyzerError.unsupportedInput, got \(error)")
            }
        }
    }

    func testImageTooSmallForBlockGridReportsCleanRatherThanCrashing() throws {
        let buffer = try Fixtures.uniformBuffer(width: 6, height: 6)
        let image = jpegImage(buffer)

        let finding = try DoubleCompressionAnalyzer().analyze(image, config: .default)

        XCTAssertEqual(finding.score, 0)
        XCTAssertTrue(finding.indicators.isEmpty)
    }

    func testDisabledAnalyzerIsSkippedByEngine() throws {
        var config = ForensicLensConfig.default
        config.doubleCompression.enabled = false
        config.ela.enabled = false
        config.metadata.enabled = false
        config.cloneDetection.enabled = false

        let engine = ForensicLensEngine(config: config)
        let image = jpegImage(try Fixtures.uniformBuffer(width: 32, height: 32))
        let report = engine.run(on: image)

        XCTAssertTrue(report.findings.isEmpty)
    }
}
