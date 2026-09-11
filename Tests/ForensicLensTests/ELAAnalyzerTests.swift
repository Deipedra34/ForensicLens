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

        // This patch's error against a uniform background sits well below
        // the old single-quality-scan threshold of 10 at every one of the
        // default quality levels individually (roughly 9.2 at quality 70,
        // 6.0 at 80, 3.1 at 90), so the threshold here is set below the
        // smallest of those instead -- ensuring all three levels agree the
        // patch is an outlier, which is what the combined, consistency-
        // weighted error map actually needs to cross `errorThreshold`. See
        // `testConsistentTamperingAcrossAllQualityLevelsIsFlagged` below
        // for a test that asserts on that consistency directly.
        var config = ForensicLensConfig.default
        config.ela.errorThreshold = 2.0
        config.ela.flaggedRegionFraction = 0.01

        let finding = try ELAAnalyzer().analyze(image, config: config)

        XCTAssertGreaterThan(finding.score, 0)
        XCTAssertFalse(finding.indicators.isEmpty)
    }

    func testConsistentTamperingAcrossAllQualityLevelsIsFlagged() throws {
        let base = try Fixtures.uniformBuffer(width: 64, height: 64, value: 100)
        // A locally re-saved/edited region: content that's structurally
        // unlike its uniform surroundings, so it responds differently to
        // recompression at every quality level tried, not just one.
        let withPatch = try Fixtures.stampingNoisePatch(of: 16, at: (x: 16, y: 16), into: base)
        let image = try Fixtures.imageData(from: withPatch)

        var config = ForensicLensConfig.default
        config.ela.errorThreshold = 2.0
        config.ela.flaggedRegionFraction = 0.01

        let finding = try ELAAnalyzer().analyze(image, config: config)

        XCTAssertGreaterThan(finding.score, 0)
        // The report should describe this region's cross-level agreement
        // explicitly, per this feature's reporting requirement.
        XCTAssertTrue(
            finding.indicators.contains { $0.message.contains("flagged at 3 of 3 quality levels") },
            "expected an indicator describing 3-of-3 quality-level agreement, got: \(finding.indicators.map(\.message))"
        )
    }

    func testQualitySpecificNoiseIsSuppressedByConsistencyWeighting() throws {
        let base = try Fixtures.uniformBuffer(width: 64, height: 64, value: 100)
        let withPatch = try Fixtures.stampingNoisePatch(of: 16, at: (x: 16, y: 16), into: base)
        let image = try Fixtures.imageData(from: withPatch)

        // At threshold 7, this patch's error independently crosses the
        // threshold at quality 70 (~9.2) but not at quality 80 (~6.0) or
        // quality 90 (~3.1) -- exactly the "quality-specific compression
        // noise" case: real, but only at one arbitrarily-chosen quality
        // level, the kind of single-level spike `combine` is meant to
        // suppress rather than let drive the score.
        var multiQuality = ForensicLensConfig.default
        multiQuality.ela.errorThreshold = 7
        multiQuality.ela.flaggedRegionFraction = 0.01

        let multiFinding = try ELAAnalyzer().analyze(image, config: multiQuality)
        XCTAssertTrue(
            multiFinding.indicators.isEmpty,
            "a region hot at only 1 of 3 quality levels should be suppressed by consistency weighting, not flagged"
        )

        // Confirm the suppression above is actually coming from cross-level
        // consistency weighting, and not just this threshold being
        // generally too strict: scanning quality 70 alone (what the old
        // single-quality analyzer would have done) at the same threshold
        // does flag it.
        var singleQuality = multiQuality
        singleQuality.ela.elaQualityLevels = [70]
        let singleFinding = try ELAAnalyzer().analyze(image, config: singleQuality)
        XCTAssertFalse(singleFinding.indicators.isEmpty)
    }

    func testHigherQualityProducesLowerOverallError() throws {
        let base = try Fixtures.noiseBuffer(width: 40, height: 40)
        let image = try Fixtures.imageData(from: base)

        var lowQuality = ForensicLensConfig.default
        lowQuality.ela.elaQualityLevels = [10]

        var highQuality = ForensicLensConfig.default
        highQuality.ela.elaQualityLevels = [95]

        let lowQualityFinding = try ELAAnalyzer().analyze(image, config: lowQuality)
        let highQualityFinding = try ELAAnalyzer().analyze(image, config: highQuality)

        // Heavier quantization at low quality should show at least as much
        // recompression error as near-lossless quantization at high quality,
        // since quantization step sizes only grow as quality drops.
        XCTAssertGreaterThanOrEqual(lowQualityFinding.score, highQualityFinding.score)
    }

    func testEmptyQualityLevelsFallsBackToDefaultRatherThanCrashing() throws {
        let base = try Fixtures.uniformBuffer(width: 64, height: 64, value: 100)
        let withPatch = try Fixtures.stampingNoisePatch(of: 16, at: (x: 16, y: 16), into: base)
        let image = try Fixtures.imageData(from: withPatch)

        var config = ForensicLensConfig.default
        config.ela.elaQualityLevels = []

        let finding = try ELAAnalyzer().analyze(image, config: config)

        // No crash, and the report still names the (fallback) quality
        // levels actually scanned.
        XCTAssertTrue(finding.summary.contains("70") && finding.summary.contains("80") && finding.summary.contains("90"))
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
