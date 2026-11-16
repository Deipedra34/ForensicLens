import XCTest
@testable import ForensicLens

/// The comparison rules of the noise-level check, on plain numbers: the
/// robust baseline, the cutoffs, the direction of a deviation, and its
/// severity.
final class NoiseDeviationTests: XCTestCase {
    // MARK: - Baseline

    func testBaselineIsTheMedianAndResistsOutliers() throws {
        let uniform = try XCTUnwrap(NoiseBaseline.of([2, 2, 2, 2, 2]))
        XCTAssertEqual(uniform.medianSigma, 2)
        XCTAssertEqual(uniform.logSpread, 0)

        // Two wild blocks out of seven move neither statistic.
        let spliced = try XCTUnwrap(NoiseBaseline.of([2, 2, 2, 2, 2, 0, 40]))
        XCTAssertEqual(spliced.medianSigma, 2)
        XCTAssertEqual(spliced.logSpread, 0)
    }

    func testBaselineSpreadMeasuresNaturalVariation() throws {
        // Ratios e^-0.2, 1, e^0.2 around the median: MAD of the logs is 0.2.
        let sigmas = [3 * exp(-0.2), 3, 3 * exp(0.2), 3, 3 * exp(-0.2), 3 * exp(0.2), 3]
        let baseline = try XCTUnwrap(NoiseBaseline.of(sigmas))
        XCTAssertEqual(baseline.medianSigma, 3, accuracy: 1e-12)
        XCTAssertEqual(baseline.logSpread, NoiseVariance.madToSigma * 0.2, accuracy: 1e-9)
    }

    func testNoBaselineWithoutMeasurableNoise() {
        XCTAssertNil(NoiseBaseline.of([]))
        XCTAssertNil(NoiseBaseline.of([0, 0, 0, 0]), "a uniform-color image has nothing to compare against")
        XCTAssertNil(NoiseBaseline.of([0, 0, 0, 1, 2]), "a majority of noiseless blocks means no usable typical level")
    }

    func testRatio() throws {
        let baseline = try XCTUnwrap(NoiseBaseline.of([4, 4, 4]))
        XCTAssertEqual(baseline.ratio(of: 2), 0.5)
        XCTAssertEqual(baseline.ratio(of: 12), 3)
    }

    // MARK: - Cutoffs

    func testCutoffsAreTheThresholdsForAUniformImage() {
        let cutoffs = NoiseDeviation.cutoffs(for: NoiseBaseline(medianSigma: 2, logSpread: 0), smoothThreshold: 0.5, noisyThreshold: 2)
        XCTAssertEqual(cutoffs, NoiseDeviation.Cutoffs(lower: 0.5, upper: 2))
    }

    func testCutoffsWidenWhenBlocksNaturallyVary() {
        // Three robust standard deviations of 0.4 in log space is a factor
        // of e^1.2 (about 3.3) either way: wider than 0.5 / 2.
        let cutoffs = NoiseDeviation.cutoffs(for: NoiseBaseline(medianSigma: 2, logSpread: 0.4), smoothThreshold: 0.5, noisyThreshold: 2)
        XCTAssertEqual(cutoffs.lower, exp(-1.2), accuracy: 1e-12)
        XCTAssertEqual(cutoffs.upper, exp(1.2), accuracy: 1e-12)

        // A narrow spread never tightens them.
        let narrow = NoiseDeviation.cutoffs(for: NoiseBaseline(medianSigma: 2, logSpread: 0.05), smoothThreshold: 0.5, noisyThreshold: 2)
        XCTAssertEqual(narrow, NoiseDeviation.Cutoffs(lower: 0.5, upper: 2))
    }

    func testThresholdsAreClampedToSensibleRanges() {
        XCTAssertEqual(NoiseDeviation.clampedThresholds(smooth: 0.5, noisy: 2).smooth, 0.5)
        XCTAssertEqual(NoiseDeviation.clampedThresholds(smooth: 1.5, noisy: 2).smooth, 0.99, "a smooth cutoff at or above 1 would flag typical blocks")
        XCTAssertEqual(NoiseDeviation.clampedThresholds(smooth: -1, noisy: 2).smooth, 0.01)
        XCTAssertEqual(NoiseDeviation.clampedThresholds(smooth: 0.5, noisy: 0.7).noisy, 1.01)
        XCTAssertEqual(NoiseDeviation.clampedThresholds(smooth: .nan, noisy: .infinity).smooth, 0.5)
        XCTAssertEqual(NoiseDeviation.clampedThresholds(smooth: .nan, noisy: .infinity).noisy, 2)
    }

    // MARK: - Direction and severity

    func testDirectionInEitherDirection() {
        let cutoffs = NoiseDeviation.Cutoffs(lower: 0.5, upper: 2)
        XCTAssertEqual(NoiseDeviation.classify(ratio: 0.2, cutoffs: cutoffs), .tooSmooth)
        XCTAssertEqual(NoiseDeviation.classify(ratio: 0, cutoffs: cutoffs), .tooSmooth, "no noise at all where the image has some")
        XCTAssertEqual(NoiseDeviation.classify(ratio: 3.5, cutoffs: cutoffs), .tooNoisy)
        XCTAssertNil(NoiseDeviation.classify(ratio: 1, cutoffs: cutoffs))
        XCTAssertNil(NoiseDeviation.classify(ratio: 0.5, cutoffs: cutoffs), "on the cutoff is not past it")
        XCTAssertNil(NoiseDeviation.classify(ratio: 2, cutoffs: cutoffs))
        XCTAssertNil(NoiseDeviation.classify(ratio: .nan, cutoffs: cutoffs))
        XCTAssertNil(NoiseDeviation.classify(ratio: -1, cutoffs: cutoffs))
    }

    func testSeverity() {
        let cutoffs = NoiseDeviation.Cutoffs(lower: 0.5, upper: 2)
        XCTAssertEqual(NoiseDeviation.severity(ratio: 0, direction: .tooSmooth, cutoffs: cutoffs), 1)
        XCTAssertEqual(NoiseDeviation.severity(ratio: 0.25, direction: .tooSmooth, cutoffs: cutoffs), 0.5, accuracy: 1e-12)
        XCTAssertEqual(NoiseDeviation.severity(ratio: 0.5, direction: .tooSmooth, cutoffs: cutoffs), 0)
        XCTAssertEqual(NoiseDeviation.severity(ratio: 4, direction: .tooNoisy, cutoffs: cutoffs), 1, accuracy: 1e-12)
        XCTAssertEqual(NoiseDeviation.severity(ratio: 2 * 2.0.squareRoot(), direction: .tooNoisy, cutoffs: cutoffs), 0.5, accuracy: 1e-12)
        XCTAssertEqual(NoiseDeviation.severity(ratio: 100, direction: .tooNoisy, cutoffs: cutoffs), 1)
        XCTAssertEqual(NoiseDeviation.severity(ratio: 1.5, direction: .tooNoisy, cutoffs: cutoffs), 0)
    }
}
