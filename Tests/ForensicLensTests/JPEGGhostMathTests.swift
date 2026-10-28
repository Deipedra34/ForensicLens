import XCTest
import ImageDecoding
@testable import ForensicLens

/// Covers the JPEG ghost building blocks on their own: the quality sweep's
/// levels, block difference maps, finding a block's ghost quality in a
/// hand-made difference curve, and the dominant-quality vote.
final class JPEGGhostMathTests: XCTestCase {
    private let qualities = [50, 55, 60, 65, 70, 75]

    // MARK: - Quality levels

    func testQualityLevelsCoverTheRangeInSteps() {
        XCTAssertEqual(JPEGGhostMath.qualityLevels(minimum: 50, maximum: 100, step: 5), Array(stride(from: 50, through: 100, by: 5)))
        XCTAssertEqual(JPEGGhostMath.qualityLevels(minimum: 100, maximum: 50, step: 5), Array(stride(from: 50, through: 100, by: 5)), "a reversed range is swapped")
        XCTAssertEqual(JPEGGhostMath.qualityLevels(minimum: 0, maximum: 120, step: 30), [1, 31, 61, 91, 100], "clamped to 1...100, always ending at the maximum")
        XCTAssertEqual(JPEGGhostMath.qualityLevels(minimum: 98, maximum: 100, step: 0), [98, 99, 100], "a non-positive step is treated as 1")
    }

    // MARK: - Ghost quality of a difference curve

    func testSteadilyFallingCurveHasNoGhost() {
        // What a never-compressed block looks like: less change at every
        // higher quality.
        XCTAssertEqual(JPEGGhostMath.ghosts(in: [10, 8, 6, 4, 2, 1], qualities: qualities), [])
        XCTAssertNil(JPEGGhostMath.ghostQuality(of: [10, 8, 6, 4, 2, 1], qualities: qualities))
    }

    func testSingleDipIsTheGhostQuality() {
        // 0.5 at 65 is below both neighbors (6 and 3) and at most 70% of 3.
        XCTAssertEqual(JPEGGhostMath.ghostQuality(of: [10, 8, 6, 0.5, 3, 1], qualities: qualities), 65)
    }

    func testLowestOfSeveralGhostsIsTheBlocksQuality() {
        // A spliced block: its own earlier save at 55, and the final save
        // of the whole image at 70.
        let curve: [Double] = [10, 4, 6, 8, 0, 2]
        XCTAssertEqual(JPEGGhostMath.ghosts(in: curve, qualities: qualities), [55, 70])
        XCTAssertEqual(JPEGGhostMath.ghostQuality(of: curve, qualities: qualities), 55)
    }

    func testShallowRippleIsNotAGhost() {
        // 5 is below its neighbors (6, 6) but only about 17% lower.
        XCTAssertNil(JPEGGhostMath.ghostQuality(of: [10, 8, 6, 5, 6, 4], qualities: qualities))
    }

    func testLowestQualityCountsButHighestNeverDoes() {
        XCTAssertEqual(JPEGGhostMath.ghosts(in: [1, 5, 4, 3], qualities: [50, 55, 60, 65]), [50], "a curve rising from its lowest quality")
        XCTAssertEqual(JPEGGhostMath.ghosts(in: [9, 8, 9, 0], qualities: [85, 90, 95, 100]), [], "the lossless end is low for any image")
    }

    func testMismatchedCurveIsIgnored() {
        XCTAssertEqual(JPEGGhostMath.ghosts(in: [1, 5, 4], qualities: qualities), [])
    }

    // MARK: - Dominant quality

    func testDominantQualityIsTheMostCommonWithTiesGoingLower() {
        XCTAssertEqual(JPEGGhostMath.dominantQuality([85, 85, 60, 85]), 85)
        XCTAssertEqual(JPEGGhostMath.dominantQuality([90, 90, 70, 70, 85]), 70)
        XCTAssertNil(JPEGGhostMath.dominantQuality([]))
    }

    // MARK: - Block differences

    func testBlockDifferencesAreMeanSquaredDifferencePerFullBlock() throws {
        let original = try Fixtures.uniformBuffer(width: 20, height: 16, channels: 1, value: 10)
        let changed = try Fixtures.uniformBuffer(width: 20, height: 16, channels: 1, value: 12)
        // 20 px wide holds two full 8px columns; the last 4 px are left out.
        XCTAssertEqual(JPEGGhostMath.blockDifferences(original: original, recompressed: changed, blockSize: 8), [4, 4, 4, 4])
        XCTAssertEqual(JPEGGhostMath.blockDifferences(original: original, recompressed: try Fixtures.uniformBuffer(width: 16, height: 16, channels: 1), blockSize: 8), [], "sizes must match")
    }

    func testRecompressingAtTheSavedQualityChangesAlmostNothing() throws {
        // The effect the whole technique rests on, through the shared
        // re-compression routine ELA uses.
        let texture = try Fixtures.smoothTextureBuffer(width: 64, height: 64)
        let saved = JPEGRecompressionSimulator.recompress(texture, quality: 85)
        let same = JPEGGhostMath.blockDifferences(original: saved, recompressed: JPEGRecompressionSimulator.recompress(saved, quality: 85), blockSize: 32)
        let other = JPEGGhostMath.blockDifferences(original: saved, recompressed: JPEGRecompressionSimulator.recompress(saved, quality: 70), blockSize: 32)
        for (atSaved, atOther) in zip(same, other) {
            XCTAssertLessThan(atSaved, 0.1)
            XCTAssertGreaterThan(atOther, 1)
        }
    }
}
