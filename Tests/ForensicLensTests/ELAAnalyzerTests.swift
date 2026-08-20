import XCTest
import ForensicLens
import ImageDecoding

final class ELAAnalyzerTests: XCTestCase {
    func testUniformImageProducesLowScore() throws {
        let buffer = try Fixtures.uniformBuffer(width: 64, height: 64)
        let image = try Fixtures.imageData(from: buffer)

        let finding = try ELAAnalyzer().analyze(image, config: .default)

        // A flat image's DCT energy is almost entirely in the DC term,
        // which survives quantization essentially untouched, so the
        // recompression pass should leave error levels low and uniform.
        XCTAssertLessThan(finding.score, 15)
    }

    func testIsolatedNoisePatchIsFlaggedAsHotRegion() throws {
        let base = try Fixtures.uniformBuffer(width: 64, height: 64, value: 100)
        // Aligned to ELAAnalyzer's 16px reporting grid so the noise patch
        // fills one reporting cell completely, rather than straddling four
        // cells and diluting the mean error in each.
        let withPatch = try Fixtures.stampingNoisePatch(of: 16, at: (x: 16, y: 16), into: base)
        let image = try Fixtures.imageData(from: withPatch)

        var config = ForensicLensConfig.default
        config.ela.errorThreshold = 10
        config.ela.flaggedRegionFraction = 0.01

        let finding = try ELAAnalyzer().analyze(image, config: config)

        XCTAssertGreaterThan(finding.score, 0)
        XCTAssertFalse(finding.indicators.isEmpty)
    }

    func testHigherQualityProducesLowerOverallError() throws {
        let base = try Fixtures.noiseBuffer(width: 40, height: 40)
        let image = try Fixtures.imageData(from: base)

        var lowQuality = ForensicLensConfig.default
        lowQuality.ela.qualityLevel = 10

        var highQuality = ForensicLensConfig.default
        highQuality.ela.qualityLevel = 95

        let lowQualityFinding = try ELAAnalyzer().analyze(image, config: lowQuality)
        let highQualityFinding = try ELAAnalyzer().analyze(image, config: highQuality)

        // Heavier quantization at low quality should show at least as much
        // recompression error as near-lossless quantization at high quality,
        // since quantization step sizes only grow as quality drops.
        XCTAssertGreaterThanOrEqual(lowQualityFinding.score, highQualityFinding.score)
    }

    func testThrowsUnsupportedInputWhenPixelsAreUnavailable() throws {
        let jpegBytes = Fixtures.jpegBytesWithNoExif()
        let image = try ImageData.load(jpegBytes)
        XCTAssertNil(image.pixels)

        XCTAssertThrowsError(try ELAAnalyzer().analyze(image, config: .default)) { error in
            guard case AnalyzerError.unsupportedInput(_) = error else {
                return XCTFail("Expected AnalyzerError.unsupportedInput, got \(error)")
            }
        }
    }

    func testCorruptImageBytesFailToLoad() {
        let garbage: [UInt8] = [0x00, 0x01, 0x02, 0x03, 0x04]
        XCTAssertThrowsError(try ImageData.load(garbage)) { error in
            XCTAssertEqual(error as? ImageDecodingError, .badMagicNumber)
        }
    }
}
