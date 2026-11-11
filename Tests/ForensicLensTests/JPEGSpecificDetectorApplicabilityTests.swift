import XCTest
import ImageDecoding
@testable import ForensicLens

/// ELA, JPEG ghost detection, and double-compression detection model JPEG's
/// 8x8 DCT compression, which HEIF/HEIC and WebP don't use. On those formats
/// they must report a clean "not applicable" -- never a score -- however
/// the image is run (single analyzer, tiled, or the whole engine), while the
/// format-agnostic analyzers still run on the decoded pixels.
final class JPEGSpecificDetectorApplicabilityTests: XCTestCase {
    private let jpegSpecificIDs = ["ela", "jpegghost", "doublecompression"]
    private let jpegSpecific: [any Analyzer] = [ELAAnalyzer(), JPEGGhostAnalyzer(), DoubleCompressionAnalyzer()]

    private func assertNotApplicable(_ finding: AnalyzerFinding, format: ImageFormat, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(finding.score, 0, finding.summary, file: file, line: line)
        XCTAssertTrue(finding.indicators.isEmpty, finding.summary, file: file, line: line)
        XCTAssertTrue(finding.summary.contains("not applicable"), finding.summary, file: file, line: line)
        XCTAssertTrue(finding.summary.contains(format == .heif ? "HEVC" : "VP8"), finding.summary, file: file, line: line)
    }

    func testJPEGSpecificDetectorsAreNotApplicableToHEIFAndWebP() throws {
        // Busy texture that ELA and ghost detection would otherwise measure.
        let pixels = try Fixtures.noiseBuffer(width: 128, height: 128, seed: 3)
        for format in [ImageFormat.heif, .webp] {
            let image = ImageData(rawBytes: [], pixels: pixels, format: format)
            for analyzer in jpegSpecific {
                assertNotApplicable(try analyzer.analyze(image, config: .default), format: format)
            }
        }
    }

    func testTiledAnalysisStillReportsNotApplicable() throws {
        let image = ImageData(rawBytes: [], pixels: try Fixtures.noiseBuffer(width: 256, height: 256, seed: 4), format: .webp)
        let report = ForensicLensEngine(config: .default).run(on: image, tiling: TilingOverride(forcedTileSize: 96))
        for id in jpegSpecificIDs {
            assertNotApplicable(try XCTUnwrap(report.findings.first { $0.analyzerID == id }, id), format: .webp)
        }
    }

    func testUncompressedFormatsStillRunTheJPEGSpecificDetectors() throws {
        // Unchanged: a BMP or PPM is often a decoded JPEG, so ELA and ghost
        // detection keep running on them.
        XCTAssertNil(ImageFormat.ppm.jpegAnalysisNotApplicableReason)
        XCTAssertNil(ImageFormat.bmp.jpegAnalysisNotApplicableReason)
        XCTAssertNil(ImageFormat.jpeg.jpegAnalysisNotApplicableReason)
        let image = try Fixtures.imageData(from: Fixtures.noiseBuffer(width: 128, height: 128, seed: 3))
        for analyzer in [ELAAnalyzer(), JPEGGhostAnalyzer()] as [any Analyzer] {
            let finding = try analyzer.analyze(image, config: .default)
            XCTAssertFalse(finding.summary.contains("HEVC") || finding.summary.contains("VP8"), finding.summary)
        }
    }

    // MARK: - Real files, full engine

    private func assertEngineSkipsOnlyJPEGSpecificDetectors(_ bytes: [UInt8], format: ImageFormat, file: StaticString = #filePath, line: UInt = #line) throws {
        let image = try ImageData.load(bytes)
        XCTAssertEqual(image.format, format, file: file, line: line)
        let report = ForensicLensEngine(config: .default).run(on: image)
        for id in jpegSpecificIDs {
            assertNotApplicable(try XCTUnwrap(report.findings.first { $0.analyzerID == id }, id), format: format, file: file, line: line)
        }
        for id in ["clone", "prnu", "cfa", "metadata", "thumbnail"] {
            let finding = try XCTUnwrap(report.findings.first { $0.analyzerID == id }, id)
            XCTAssertFalse(finding.summary.hasPrefix("Could not run"), "\(id): \(finding.summary)", file: file, line: line)
        }
    }

    func testDecodedWebPFileSkipsOnlyTheJPEGSpecificDetectors() throws {
        try assertEngineSkipsOnlyJPEGSpecificDetectors(Fixtures.webpFile(Fixtures.noiseBuffer(width: 96, height: 96, seed: 6)), format: .webp)
    }

    func testDecodedHEIFFileSkipsOnlyTheJPEGSpecificDetectors() throws {
        try assertEngineSkipsOnlyJPEGSpecificDetectors(Fixtures.heifFile(Fixtures.noiseBuffer(width: 96, height: 96, seed: 6), quality: 90), format: .heif)
    }
}
