import XCTest
import ImageDecoding
@testable import ForensicLens

/// Covers `SpectralArtifactDetector` and its measurement on synthetic
/// inputs: a deliberately constructed periodic grid should score high,
/// natural-photo-like noise should score exactly 0.
final class SpectralArtifactDetectorTests: XCTestCase {
    private func measure(_ buffer: PixelBuffer) -> SpectralArtifactMeasurement {
        SpectralArtifactDetector.measure(PRNUPlane.luminance(of: buffer))
    }

    // MARK: - Lattice frequencies

    func testLatticeFrequenciesCoverEveryMultipleOfAnEighthOncePerConjugatePair() {
        let size = 64
        let bins = SpectralArtifactDetector.latticeFrequencies(size: size)
        // 8x8 multiples of size/8, minus DC, is 63 bins. Conjugate pairs
        // collapse to one, except the 3 self-conjugate Nyquist bins.
        XCTAssertEqual(bins.count, (63 - 3) / 2 + 3)
        XCTAssertEqual(Set(bins).count, bins.count)
        XCTAssertFalse(bins.contains(.init(u: 0, v: 0)))
        for bin in bins {
            XCTAssertEqual(bin.u % 8, 0)
            XCTAssertEqual(bin.v % 8, 0)
            XCTAssertEqual(SpectralArtifactDetector.canonical(bin, size: size), bin)
        }
        XCTAssertTrue(bins.contains(.init(u: 32, v: 32)))
    }

    func testPeriodOfABinIsTheShortestLatticeContainingIt() {
        XCTAssertEqual(SpectralArtifactDetector.period(of: .init(u: 32, v: 32), size: 64), 2)
        XCTAssertEqual(SpectralArtifactDetector.period(of: .init(u: 16, v: 0), size: 64), 4)
        XCTAssertEqual(SpectralArtifactDetector.period(of: .init(u: 8, v: 24), size: 64), 8)
        XCTAssertEqual(SpectralArtifactDetector.period(of: .init(u: 3, v: 0), size: 64), 0)
    }

    func testCropSizeIsTheLargestFittingPowerOfTwoWithinBounds() {
        XCTAssertNil(SpectralArtifactDetector.cropSize(width: 63, height: 500))
        XCTAssertEqual(SpectralArtifactDetector.cropSize(width: 64, height: 64), 64)
        XCTAssertEqual(SpectralArtifactDetector.cropSize(width: 300, height: 200), 128)
        XCTAssertEqual(SpectralArtifactDetector.cropSize(width: 4000, height: 3000), 512)
        XCTAssertEqual(SpectralArtifactDetector.cropRegion(width: 300, height: 200), Region(x: 86, y: 36, width: 128, height: 128))
    }

    // MARK: - Grid pattern vs. natural noise

    func testUpsamplingGridScoresHigh() throws {
        let measurement = measure(try Fixtures.likelyGeneratedImage())
        XCTAssertEqual(measurement.status, .measured)
        let strongest = try XCTUnwrap(measurement.strongestPeak)
        XCTAssertEqual(strongest.bin, .init(u: 128, v: 128), "the checkerboard's Nyquist bin should dominate")
        XCTAssertEqual(strongest.period, 2)
        XCTAssertGreaterThan(strongest.ratio, 1_000)
        XCTAssertEqual(measurement.artifactScore(sensitivity: 0.5), 1, accuracy: 1e-9)

        let threshold = SpectralArtifactMeasurement.peakRatioThreshold(sensitivity: 0.5)
        let periods = Set(measurement.flaggedPeaks(threshold: threshold).map(\.period))
        XCTAssertTrue(periods.contains(2))
        XCTAssertTrue(periods.contains(4), "the period-4 component should be found too")
    }

    func testUpsamplingGridIsFoundUnderCameraNoise() throws {
        let buffer = try Fixtures.addingUpsamplingPattern(to: Fixtures.likelyCameraImage(), checkerboard: 1.5, period4: 1)
        let measurement = measure(buffer)
        XCTAssertGreaterThan(measurement.artifactScore(sensitivity: 0.5), 0.9)
    }

    func testNaturalPhotoLikeNoiseScoresZero() throws {
        for (sceneSeed, seed) in [(3, UInt64(41)), (7, 99), (11, 1234), (2, 5)] {
            let measurement = measure(try Fixtures.cameraLikeCapture(sceneSeed: sceneSeed, seed: seed))
            XCTAssertEqual(measurement.status, .measured)
            let strongest = try XCTUnwrap(measurement.strongestPeak)
            XCTAssertLessThan(strongest.ratio, 20, "scene \(sceneSeed): chance peaks stay well under the default threshold")
            XCTAssertEqual(measurement.artifactScore(sensitivity: 0.5), 0)
        }
    }

    func testWhiteNoiseImageScoresZero() throws {
        var generator = Fixtures.SeededGenerator(seed: 77)
        let pixels = (0..<(256 * 256)).map { _ in UInt8(clamping: Int((128 + 20 * Fixtures.nextGaussian(&generator)).rounded())) }
        let measurement = measure(try PixelBuffer(width: 256, height: 256, channels: 1, pixels: pixels))
        XCTAssertEqual(measurement.artifactScore(sensitivity: 0.5), 0)
    }

    // MARK: - Sensitivity and score shape

    func testThresholdFollowsSensitivityAndIsClamped() {
        XCTAssertEqual(SpectralArtifactMeasurement.peakRatioThreshold(sensitivity: 0), 100, accuracy: 1e-9)
        XCTAssertEqual(SpectralArtifactMeasurement.peakRatioThreshold(sensitivity: 1), 10, accuracy: 1e-9)
        XCTAssertEqual(SpectralArtifactMeasurement.peakRatioThreshold(sensitivity: 0.5), pow(10, 1.5), accuracy: 1e-9)
        XCTAssertEqual(SpectralArtifactMeasurement.peakRatioThreshold(sensitivity: -3), 100, accuracy: 1e-9)
        XCTAssertEqual(SpectralArtifactMeasurement.peakRatioThreshold(sensitivity: 9), 10, accuracy: 1e-9)
        XCTAssertEqual(SpectralArtifactMeasurement.peakRatioThreshold(sensitivity: .nan), pow(10, 1.5), accuracy: 1e-9)
    }

    func testScoreStartsAtOneHalfAtTheThresholdAndSaturates() {
        func measurement(ratio: Double) -> SpectralArtifactMeasurement {
            SpectralArtifactMeasurement(
                status: .measured,
                analyzedRegion: Region(x: 0, y: 0, width: 64, height: 64),
                cropSize: 64,
                peaks: [.init(bin: .init(u: 32, v: 32), period: 2, ratio: ratio)]
            )
        }
        XCTAssertEqual(measurement(ratio: 99).artifactScore(sensitivity: 0), 0)
        XCTAssertEqual(measurement(ratio: 100).artifactScore(sensitivity: 0), 0.5, accuracy: 1e-9)
        XCTAssertEqual(measurement(ratio: 3_000).artifactScore(sensitivity: 0), 1, accuracy: 1e-9)
        XCTAssertEqual(measurement(ratio: 1e6).artifactScore(sensitivity: 0), 1)
        let middle = measurement(ratio: 100 * 30.0.squareRoot()).artifactScore(sensitivity: 0)
        XCTAssertEqual(middle, 0.75, accuracy: 1e-9)
    }

    func testHigherSensitivityNeverLowersTheScore() throws {
        let measurement = measure(try Fixtures.addingUpsamplingPattern(to: Fixtures.likelyCameraImage(), checkerboard: 0.4, period4: 0))
        var previous = -1.0
        for sensitivity in stride(from: 0.0, through: 1.0, by: 0.1) {
            let score = measurement.artifactScore(sensitivity: sensitivity)
            XCTAssertGreaterThanOrEqual(score, previous)
            previous = score
        }
    }
}
