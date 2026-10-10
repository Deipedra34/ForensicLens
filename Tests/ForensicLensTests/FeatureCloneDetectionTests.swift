import XCTest
@testable import ForensicLens
import ImageDecoding

/// End-to-end coverage of the rotation/scale-tolerant clone detection pass:
/// synthetic copy-move forgeries whose pasted patch was rotated and/or
/// rescaled first, built in memory from `Fixtures.smoothTextureBuffer` and
/// `Fixtures.pastingTransformedPatch`, so the ground truth -- where the
/// patch came from, where it went, and how it was transformed -- is known
/// exactly.
final class FeatureCloneDetectionTests: XCTestCase {
    private let imageSize = 192
    private let patchSize = 64
    private let sourceOrigin = (x: 16, y: 16)
    private var sourceRegion: Region { Region(x: sourceOrigin.x, y: sourceOrigin.y, width: patchSize, height: patchSize) }

    private var detector: FeatureCloneDetector {
        FeatureCloneDetector(settings: .init(ForensicLensConfig.default.cloneDetection))
    }

    /// The standard forgery for these tests: the 64x64 patch at (16, 16)
    /// of a 192x192 texture, transformed and pasted into the opposite
    /// corner.
    private func forgery(rotationDegrees: Double, scale: Double) throws -> (buffer: PixelBuffer, pastedBounds: Region) {
        let base = try Fixtures.smoothTextureBuffer(width: imageSize, height: imageSize, seed: 7)
        let center = Double(imageSize) - 56
        return try Fixtures.pastingTransformedPatch(
            of: patchSize,
            from: sourceOrigin,
            centeredOn: (x: center, y: center),
            rotationDegrees: rotationDegrees,
            scale: scale,
            into: base
        )
    }

    private func intersectionOverUnion(_ a: Region, _ b: Region) -> Double {
        guard let overlap = a.intersection(b) else { return 0 }
        let overlapArea = Double(overlap.width * overlap.height)
        return overlapArea / (Double(a.width * a.height + b.width * b.height) - overlapArea)
    }

    /// Asserts exactly one clone pair was found, located on the known
    /// source and pasted regions, with the expected transform.
    private func assertDetectsSingleClone(
        _ result: FeatureCloneDetectionResult,
        pastedBounds: Region,
        rotationDegrees: Double,
        scale: Double,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(result.outcome, .cloneDetected, result.summary, file: file, line: line)
        XCTAssertEqual(result.pairs.count, 1, file: file, line: line)
        let pair = try XCTUnwrap(result.pairs.first, file: file, line: line)

        XCTAssertEqual(pair.rotationDegrees, rotationDegrees, accuracy: 3, file: file, line: line)
        XCTAssertEqual(pair.scale, scale, accuracy: 0.06, file: file, line: line)
        XCTAssertGreaterThanOrEqual(pair.inlierCount, ForensicLensConfig.default.cloneDetection.minimumMatchedKeypoints, file: file, line: line)

        // The source patch is first in reading order, so it's always
        // reported as `source` and the pasted copy as `target`.
        XCTAssertGreaterThan(intersectionOverUnion(pair.source, sourceRegion), 0.4, "source \(pair.source) vs. truth \(sourceRegion)", file: file, line: line)
        XCTAssertGreaterThan(intersectionOverUnion(pair.target, pastedBounds), 0.4, "target \(pair.target) vs. truth \(pastedBounds)", file: file, line: line)
    }

    // MARK: - Detecting transformed clones

    func testRotatedCloneIsDetectedWithItsRotationRecovered() throws {
        let forged = try forgery(rotationDegrees: 30, scale: 1)
        try assertDetectsSingleClone(detector.detect(in: forged.buffer), pastedBounds: forged.pastedBounds, rotationDegrees: 30, scale: 1)
    }

    func testRescaledCloneIsDetectedWithItsScaleRecovered() throws {
        let forged = try forgery(rotationDegrees: 0, scale: 1.25)
        try assertDetectsSingleClone(detector.detect(in: forged.buffer), pastedBounds: forged.pastedBounds, rotationDegrees: 0, scale: 1.25)
    }

    func testRotatedAndShrunkCloneIsDetected() throws {
        let forged = try forgery(rotationDegrees: 45, scale: 0.8)
        try assertDetectsSingleClone(detector.detect(in: forged.buffer), pastedBounds: forged.pastedBounds, rotationDegrees: 45, scale: 0.8)
    }

    func testCloneRotatedByNinetyDegreesIsDetected() throws {
        let forged = try forgery(rotationDegrees: 90, scale: 1)
        try assertDetectsSingleClone(detector.detect(in: forged.buffer), pastedBounds: forged.pastedBounds, rotationDegrees: 90, scale: 1)
    }

    func testDetectionIsDeterministic() throws {
        let forged = try forgery(rotationDegrees: 30, scale: 1)
        XCTAssertEqual(detector.detect(in: forged.buffer), detector.detect(in: forged.buffer))
    }

    // MARK: - No false positives, no crashes

    func testAuthenticTextureHasNoFeatureClone() throws {
        for seed: UInt64 in [3, 11] {
            let authentic = try Fixtures.smoothTextureBuffer(width: 256, height: 256, seed: seed)
            let result = detector.detect(in: authentic)
            XCTAssertTrue(result.pairs.isEmpty, "seed \(seed): \(result.pairs)")
            XCTAssertNotEqual(result.outcome, .cloneDetected)
        }
    }

    func testPixelNoiseHasNoFeatureClone() throws {
        let noise = try Fixtures.noiseBuffer(width: 128, height: 128, seed: 42)
        let result = detector.detect(in: noise)
        XCTAssertTrue(result.pairs.isEmpty)
        XCTAssertNotEqual(result.outcome, .cloneDetected)
    }

    func testFlatImageReportsTooFewKeypoints() throws {
        let flat = try Fixtures.uniformBuffer(width: 96, height: 96)
        let result = detector.detect(in: flat)

        XCTAssertEqual(result.outcome, .tooFewKeypoints)
        XCTAssertEqual(result.keypointCount, 0)
        XCTAssertTrue(result.pairs.isEmpty)
        XCTAssertTrue(result.summary.hasPrefix("No clone detected via feature matching"), result.summary)
    }

    func testImageTooSmallForAnyKeypointIsHandledGracefully() throws {
        let tiny = try Fixtures.noiseBuffer(width: 8, height: 8)
        let result = detector.detect(in: tiny)

        XCTAssertEqual(result.outcome, .tooFewKeypoints)
        XCTAssertTrue(result.pairs.isEmpty)
    }

    func testOutOfRangeSettingsAreClampedRatherThanTrapping() throws {
        let forged = try forgery(rotationDegrees: 30, scale: 1)
        let hostile = FeatureCloneDetector(settings: .init(minimumMatchedKeypoints: -5, reprojectionThreshold: .nan, maximumKeypoints: 0, minimumMatchDistance: -1))
        // Whatever it concludes, it must conclude it without crashing.
        _ = hostile.detect(in: forged.buffer)
    }

    // MARK: - Pipeline integration

    func testBlockMatchingAloneMissesARotatedCloneThatFeatureMatchingCatches() throws {
        let forged = try forgery(rotationDegrees: 30, scale: 1)
        let image = try Fixtures.imageData(from: forged.buffer)

        var blockOnly = ForensicLensConfig.default
        blockOnly.cloneDetection.featureMatchingEnabled = false
        let blockFinding = try CloneDetectionAnalyzer().analyze(image, config: blockOnly)
        XCTAssertEqual(blockFinding.score, 0, "a rotated patch shouldn't match its source pixel-for-pixel")

        let finding = try CloneDetectionAnalyzer().analyze(image, config: .default)
        XCTAssertGreaterThan(finding.score, 0)
        XCTAssertTrue(finding.summary.contains("feature matching"), finding.summary)

        let indicator = try XCTUnwrap(finding.indicators.first)
        XCTAssertTrue(indicator.message.contains("under a rotation of"), indicator.message)
        XCTAssertEqual(indicator.regions.count, 2, "one region for the source, one for the pasted copy")
    }

    func testFeatureCloneDrivesTheOverallSuspicionScore() throws {
        let forged = try forgery(rotationDegrees: 45, scale: 0.8)
        let image = try Fixtures.imageData(from: forged.buffer)

        let report = ForensicLensEngine(config: .default).run(on: image, only: ["clone"])

        XCTAssertGreaterThanOrEqual(report.overallScore, 70)
        XCTAssertEqual(report.verdict, "likely manipulated")
    }

    func testAuthenticImageCloneFindingIsUnchangedByFeatureMatching() throws {
        let authentic = try Fixtures.imageData(from: Fixtures.smoothTextureBuffer(width: 192, height: 192, seed: 3))

        var blockOnly = ForensicLensConfig.default
        blockOnly.cloneDetection.featureMatchingEnabled = false

        XCTAssertEqual(
            try CloneDetectionAnalyzer().analyze(authentic, config: .default),
            try CloneDetectionAnalyzer().analyze(authentic, config: blockOnly)
        )
    }

    func testRotatedCloneSpanningTilesIsDetectedWhenTiled() throws {
        let base = try Fixtures.smoothTextureBuffer(width: 256, height: 256, seed: 7)
        let forged = try Fixtures.pastingTransformedPatch(of: 64, from: (x: 24, y: 24), centeredOn: (x: 190, y: 186), rotationDegrees: 30, scale: 1.2, into: base)
        let image = try Fixtures.imageData(from: forged.buffer)

        // `TiledCloneDetection` lays out its own tile grid from
        // `tiling.tileSize`, so set it to match the forced size: the
        // source (top-left tile) and the copy (bottom-right tiles) then
        // genuinely land in different tiles of a 3x3 grid.
        var config = ForensicLensConfig.default
        config.tiling.tileSize = 96
        let tiles = TilingCoordinator.plan(for: image, config: config, override: TilingOverride(forcedTileSize: 96))
        XCTAssertGreaterThan(tiles?.count ?? 0, 1)

        let report = ForensicLensEngine(config: config).run(on: image, only: ["clone"], tiling: TilingOverride(forcedTileSize: 96))
        let finding = try XCTUnwrap(report.findings.first)
        XCTAssertGreaterThan(finding.score, 0, finding.summary)
        XCTAssertTrue(finding.indicators.contains { $0.message.contains("under a rotation of") }, "\(finding.indicators.map(\.message))")
    }
}
