import XCTest
import ImageDecoding
@testable import ForensicLens

/// Covers the global PRNU-absence check (`PRNUGlobalPresence`): an image
/// with a simulated camera noise pattern shouldn't flag, one with no noise
/// pattern at all should, and it must behave differently from the local
/// consistency check on exactly the images where the two disagree.
final class PRNUGlobalPresenceTests: XCTestCase {
    private let threshold = ForensicLensConfig.AIGeneratedConfig.default.prnuAbsenceThreshold

    // MARK: - Camera noise vs. none

    func testSimulatedCameraNoiseIsPresentEverywhereAndDoesNotFlag() throws {
        let assessment = PRNUGlobalPresence.assess(try Fixtures.likelyCameraImage(), settings: .default)
        XCTAssertEqual(assessment.status, .assessed)
        XCTAssertEqual(assessment.reliableBlockCount, 16)
        XCTAssertEqual(assessment.coverage, 1, accuracy: 1e-9)
        XCTAssertGreaterThan(assessment.medianNoiseLevel, 1)
        XCTAssertEqual(assessment.absenceSignal(threshold: threshold), 0)
        XCTAssertFalse(assessment.lacksFingerprint(threshold: threshold))
    }

    func testImageWithNoNoisePatternFlags() throws {
        let assessment = PRNUGlobalPresence.assess(try Fixtures.noiseFreeRender(), settings: .default)
        XCTAssertEqual(assessment.status, .assessed)
        XCTAssertEqual(assessment.sensorLikeBlockCount, 0)
        XCTAssertLessThan(assessment.medianNoiseLevel, PRNUGlobalPresence.minimumSensorNoiseLevel)
        XCTAssertEqual(assessment.absenceSignal(threshold: threshold), 1, accuracy: 1e-9)
        XCTAssertTrue(assessment.lacksFingerprint(threshold: threshold))
    }

    func testPeriodicNonSensorNoiseDoesNotCountAsAFingerprint() throws {
        // Plenty of residual energy, but it's a strongly correlated grid,
        // not near-white sensor noise.
        let assessment = PRNUGlobalPresence.assess(try Fixtures.likelyGeneratedImage(), settings: .default)
        XCTAssertGreaterThan(assessment.medianNoiseLevel, PRNUGlobalPresence.minimumSensorNoiseLevel)
        XCTAssertEqual(assessment.sensorLikeBlockCount, 0)
        XCTAssertEqual(assessment.absenceSignal(threshold: threshold), 1, accuracy: 1e-9)
    }

    func testSmoothedNoiseDoesNotCountAsAFingerprint() {
        // Box-filtered white noise: strong enough, but correlated between
        // neighbors the way upsampled or synthesized noise is.
        let size = 128
        var generator = Fixtures.SeededGenerator(seed: 9)
        let white = (0..<(size * size)).map { _ in 6 * Fixtures.nextGaussian(&generator) }
        let smooth = PRNUResidualExtractor.localMeans(of: white, width: size, height: size, window: 5)
        let residual = PRNUPlane(width: size, height: size, values: smooth.map { $0 * 3 })
        let luma = PRNUPlane(width: size, height: size, repeating: 120)
        let assessment = PRNUGlobalPresence.assess(residual: residual, luma: luma, blockSize: 32, minimumReliableBlocks: 4)
        XCTAssertEqual(assessment.status, .assessed)
        XCTAssertEqual(assessment.sensorLikeBlockCount, 0)
    }

    func testCoverageIsTheShareOfSensorLikeBlocks() throws {
        // Camera noise in the left half of the residual, none on the right.
        let size = 128
        var generator = Fixtures.SeededGenerator(seed: 4)
        var values = [Double](repeating: 0, count: size * size)
        for y in 0..<size {
            for x in 0..<(size / 2) { values[y * size + x] = 2.5 * Fixtures.nextGaussian(&generator) }
        }
        let assessment = PRNUGlobalPresence.assess(
            residual: PRNUPlane(width: size, height: size, values: values),
            luma: PRNUPlane(width: size, height: size, repeating: 120),
            blockSize: 32,
            minimumReliableBlocks: 4
        )
        XCTAssertEqual(assessment.reliableBlockCount, 16)
        XCTAssertEqual(assessment.sensorLikeBlockCount, 8)
        XCTAssertEqual(assessment.coverage, 0.5, accuracy: 1e-9)
        XCTAssertEqual(assessment.absenceSignal(threshold: 0.5), 0)
        XCTAssertEqual(assessment.absenceSignal(threshold: 1), 0.5, accuracy: 1e-9)
    }

    // MARK: - Complementing the local check

    func testLocalConsistencyCallsANoiselessImageConsistentWhileTheGlobalCheckFlagsIt() throws {
        // Noise that's uniformly absent has no outlier block for the local
        // check to find; the global check is what catches it.
        let buffer = try Fixtures.likelyGeneratedImage()
        let map = try XCTUnwrap(PRNUAnalyzer.consistencyMap(for: buffer, settings: .default))
        XCTAssertTrue(map.inconsistentBlocks.isEmpty, "every block is equally free of sensor noise, so none stands out locally")
        XCTAssertTrue(PRNUGlobalPresence.assess(buffer, settings: .default).lacksFingerprint(threshold: threshold))
    }

    func testLocallyTamperedCameraImageStillCarriesAFingerprint() throws {
        // A real photo with one noise-free pasted patch: the local check's
        // job, not this one's. Most of the frame keeps its sensor noise.
        let camera = try Fixtures.likelyCameraImage()
        let spliced = try Fixtures.splicing(.noiseFree, sceneSeed: 3, at: 64, 64, size: 64, into: camera)
        let assessment = PRNUGlobalPresence.assess(spliced, settings: .default)
        XCTAssertGreaterThanOrEqual(assessment.coverage, 0.75)
        XCTAssertEqual(assessment.absenceSignal(threshold: threshold), 0)
    }

    // MARK: - Threshold and degenerate input

    func testAbsenceSignalIsLinearBelowTheThresholdAndOffAtZero() {
        let assessment = PRNUPresenceAssessment(status: .assessed, reliableBlockCount: 10, sensorLikeBlockCount: 2, medianNoiseLevel: 1)
        XCTAssertEqual(assessment.absenceSignal(threshold: 0.4), 0.5, accuracy: 1e-9)
        XCTAssertEqual(assessment.absenceSignal(threshold: 0.2), 0, accuracy: 1e-9)
        XCTAssertEqual(assessment.absenceSignal(threshold: 0), 0)
        XCTAssertEqual(assessment.absenceSignal(threshold: 7), 0.8, accuracy: 1e-9, "clamped to 1")
        XCTAssertEqual(assessment.absenceSignal(threshold: .nan), 0)
    }

    func testTooSmallOrClippedImagesAreInsufficientAndNeverFlag() throws {
        let tiny = try PixelBuffer(width: 20, height: 20, channels: 1, pixels: [UInt8](repeating: 50, count: 400))
        let one = try PixelBuffer(width: 1, height: 1, channels: 3, pixels: [10, 20, 30])
        let clipped = try PixelBuffer(width: 256, height: 256, channels: 1, pixels: [UInt8](repeating: 255, count: 256 * 256))
        for buffer in [tiny, one, clipped] {
            let assessment = PRNUGlobalPresence.assess(buffer, settings: .default)
            XCTAssertFalse(assessment.isAssessed, "\(buffer.width)x\(buffer.height)")
            XCTAssertEqual(assessment.absenceSignal(threshold: 1), 0)
        }
    }
}
