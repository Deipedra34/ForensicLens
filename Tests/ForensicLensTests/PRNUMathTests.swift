import XCTest
import ImageDecoding
@testable import ForensicLens

/// Covers the numerical building blocks of PRNU analysis on their own --
/// the wavelet transform, the Wiener residual, the FFT, and the
/// correlation/scoring formulas -- using small synthetic inputs whose
/// correct outputs are known exactly or analytically.
final class PRNUMathTests: XCTestCase {
    // MARK: - Helpers

    private func gaussianPlane(width: Int, height: Int, seed: UInt64, scale: Double = 1) -> PRNUPlane {
        var generator = Fixtures.SeededGenerator(seed: seed)
        return PRNUPlane(width: width, height: height, values: (0..<(width * height)).map { _ in scale * Fixtures.nextGaussian(&generator) })
    }

    private func maxDifference(_ a: [Double], _ b: [Double]) -> Double {
        zip(a, b).reduce(0.0) { max($0, abs($1.0 - $1.1)) }
    }

    // MARK: - PRNUPlane

    func testLuminanceUsesUnroundedRec601Weights() throws {
        let buffer = try PixelBuffer(width: 2, height: 1, channels: 3, pixels: [10, 20, 30, 255, 255, 255])
        let luma = PRNUPlane.luminance(of: buffer)
        XCTAssertEqual(luma.values[0], 18.15, accuracy: 1e-9)
        XCTAssertEqual(luma.values[1], 255, accuracy: 1e-9)
    }

    func testDownsampleAveragesCellsAndDropsPartialEdges() {
        let plane = PRNUPlane(width: 5, height: 4, values: (0..<20).map(Double.init))
        let half = plane.downsampled(by: 2)
        XCTAssertEqual(half.width, 2)
        XCTAssertEqual(half.height, 2)
        // Top-left cell is (0, 1, 5, 6); the fifth column is dropped.
        XCTAssertEqual(half.values, [3, 5, 13, 15])
        XCTAssertEqual(plane.downsampled(by: 1), plane)
    }

    func testMirrorPaddingReflectsAboutTheEdges() {
        let plane = PRNUPlane(width: 3, height: 1, values: [1, 2, 3])
        XCTAssertEqual(plane.mirrorPadded(toWidth: 8, height: 2).values, [1, 2, 3, 3, 2, 1, 1, 2, 1, 2, 3, 3, 2, 1, 1, 2])
    }

    func testCropClipsToBounds() {
        let plane = PRNUPlane(width: 4, height: 3, values: (0..<12).map(Double.init))
        let crop = plane.cropped(to: Region(x: 2, y: 1, width: 5, height: 5))
        XCTAssertEqual(crop.width, 2)
        XCTAssertEqual(crop.height, 2)
        XCTAssertEqual(crop.values, [6, 7, 10, 11])
        XCTAssertEqual(plane.cropped(to: Region(x: 10, y: 10, width: 2, height: 2)).values, [])
    }

    // MARK: - Wavelet

    func testWaveletFiltersAreOrthonormal() {
        let h = DaubechiesWavelet.lowPass
        XCTAssertEqual(h.reduce(0, +), 2.0.squareRoot(), accuracy: 1e-12)
        XCTAssertEqual(h.reduce(0) { $0 + $1 * $1 }, 1, accuracy: 1e-12)
        for shift in 1..<4 {
            let overlap = (0..<(h.count - 2 * shift)).reduce(0.0) { $0 + h[$1] * h[$1 + 2 * shift] }
            XCTAssertEqual(overlap, 0, accuracy: 1e-12, "even shift \(shift)")
        }
    }

    func testWaveletInverseReconstructsTheInputExactly() {
        let original = gaussianPlane(width: 32, height: 48, seed: 5, scale: 40)
        var plane = original
        DaubechiesWavelet.forward(&plane, levels: 4)
        XCTAssertGreaterThan(maxDifference(plane.values, original.values), 1, "the forward transform should actually change the data")
        DaubechiesWavelet.inverse(&plane, levels: 4)
        XCTAssertLessThan(maxDifference(plane.values, original.values), 1e-9)
    }

    func testWaveletPreservesEnergy() {
        let original = gaussianPlane(width: 32, height: 32, seed: 6)
        var plane = original
        DaubechiesWavelet.forward(&plane, levels: 3)
        let before = original.values.reduce(0) { $0 + $1 * $1 }
        let after = plane.values.reduce(0) { $0 + $1 * $1 }
        XCTAssertEqual(after, before, accuracy: before * 1e-12)
    }

    func testConstantPlaneHasNoDetailAndScaledApproximation() {
        var plane = PRNUPlane(width: 32, height: 32, repeating: 10)
        DaubechiesWavelet.forward(&plane, levels: 4)
        // Each level scales a constant by sqrt(2) per axis, so by 2 in 2D.
        let approximation = plane.cropped(to: Region(x: 0, y: 0, width: 2, height: 2)).values
        for value in approximation { XCTAssertEqual(value, 160, accuracy: 1e-9) }
        for level in 1...4 {
            for band in DaubechiesWavelet.detailSubbands(width: 32, height: 32, level: level) {
                let detail = plane.cropped(to: Region(x: band.x, y: band.y, width: band.width, height: band.height)).values
                XCTAssertLessThan(detail.map(abs).max() ?? 0, 1e-9, "level \(level) detail should vanish on a constant")
            }
        }
    }

    func testWaveletRefusesSizesNotDivisibleByTheLevelCount() {
        XCTAssertFalse(DaubechiesWavelet.canTransform(width: 24, height: 32, levels: 4))
        let original = PRNUPlane(width: 24, height: 32, repeating: 1)
        var plane = original
        DaubechiesWavelet.forward(&plane, levels: 4)
        XCTAssertEqual(plane, original)
    }

    // MARK: - Residual extraction

    func testWienerResidualKeepsNoiseAndShrinksStrongSignal() {
        // Every coefficient 1: local mean square 1 < sigma0^2 = 9, so the
        // signal variance estimate is 0 and the coefficient is all residual.
        let weak = PRNUResidualExtractor.wienerResidual([Double](repeating: 1, count: 25), width: 5, height: 5, noiseVariance: 9)
        for value in weak { XCTAssertEqual(value, 1, accuracy: 1e-12) }

        // Every coefficient 30: signal variance 900 - 9 = 891, so the
        // residual is 30 * 9 / (891 + 9) = 0.3.
        let strong = PRNUResidualExtractor.wienerResidual([Double](repeating: 30, count: 25), width: 5, height: 5, noiseVariance: 9)
        for value in strong { XCTAssertEqual(value, 0.3, accuracy: 1e-12) }
    }

    func testLocalMeansClipAtEdges() {
        let values: [Double] = [1, 2, 3, 4, 5, 6, 7, 8, 9]
        let means = PRNUResidualExtractor.localMeans(of: values, width: 3, height: 3, window: 3)
        XCTAssertEqual(means[4], 5, accuracy: 1e-12)
        XCTAssertEqual(means[0], 3, accuracy: 1e-12) // mean of 1, 2, 4, 5
        XCTAssertEqual(means[8], 7, accuracy: 1e-12) // mean of 5, 6, 8, 9
    }

    func testZeroMeaningLeavesEveryRowAndColumnSummingToZero() {
        let plane = PRNUResidualExtractor.zeroMeaned(gaussianPlane(width: 7, height: 5, seed: 8, scale: 3))
        for y in 0..<5 {
            XCTAssertEqual((0..<7).reduce(0.0) { $0 + plane[$1, y] }, 0, accuracy: 1e-9)
        }
        for x in 0..<7 {
            XCTAssertEqual((0..<5).reduce(0.0) { $0 + plane[x, $1] }, 0, accuracy: 1e-9)
        }
    }

    func testUniformImageHasZeroResidual() {
        let residual = PRNUResidualExtractor.residual(of: PRNUPlane(width: 40, height: 24, repeating: 128))
        XCTAssertEqual(residual.width, 40)
        XCTAssertEqual(residual.height, 24)
        XCTAssertLessThan(residual.values.map(abs).max() ?? 0, 1e-9)
    }

    func testResidualOfSmoothSceneWithNoiseRecoversTheNoise() {
        // A smooth ramp plus white noise well under sigma0: the residual
        // should be nearly the noise itself, not the ramp.
        let width = 64
        let height = 64
        let noise = gaussianPlane(width: width, height: height, seed: 9, scale: 1.5)
        var values = [Double](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                values[y * width + x] = 60 + Double(x) + 0.5 * Double(y) + noise[x, y]
            }
        }
        let residual = PRNUResidualExtractor.residual(of: PRNUPlane(width: width, height: height, values: values))
        let correlation = PRNUCorrelation.normalizedCrossCorrelation(residual.values, noise.values)
        XCTAssertGreaterThan(correlation ?? 0, 0.85)
    }

    // MARK: - FFT

    func testFFTOfKnownSequence() throws {
        let plan = try XCTUnwrap(FFT.Plan(size: 4))
        var real: [Double] = [1, 2, 3, 4]
        var imaginary: [Double] = [0, 0, 0, 0]
        FFT.transform(&real, &imaginary, plan: plan, inverse: false)
        XCTAssertLessThan(maxDifference(real, [10, -2, -2, -2]), 1e-12)
        XCTAssertLessThan(maxDifference(imaginary, [0, 2, 0, -2]), 1e-12)
    }

    func testFFTOfImpulseIsFlatAndRoundTrips() throws {
        let plan = try XCTUnwrap(FFT.Plan(size: 16))
        var real = [Double](repeating: 0, count: 16)
        var imaginary = real
        real[0] = 1
        FFT.transform(&real, &imaginary, plan: plan, inverse: false)
        XCTAssertLessThan(maxDifference(real, [Double](repeating: 1, count: 16)), 1e-12)
        XCTAssertLessThan(imaginary.map(abs).max() ?? 0, 1e-12)

        let original = gaussianPlane(width: 16, height: 1, seed: 10).values
        var roundTripReal = original
        var roundTripImaginary = [Double](repeating: 0, count: 16)
        FFT.transform(&roundTripReal, &roundTripImaginary, plan: plan, inverse: false)
        FFT.transform(&roundTripReal, &roundTripImaginary, plan: plan, inverse: true)
        XCTAssertLessThan(maxDifference(roundTripReal, original), 1e-12)
    }

    func testFFTRejectsNonPowerOfTwoSizes() {
        XCTAssertNil(FFT.Plan(size: 12))
        XCTAssertNil(FFT.circularCrossCorrelation([Double](repeating: 0, count: 12), [Double](repeating: 0, count: 12), width: 4, height: 3))
        XCTAssertEqual(FFT.nextPowerOfTwo(100), 128)
        XCTAssertEqual(FFT.nextPowerOfTwo(64), 64)
    }

    func testCircularCrossCorrelationPeaksAtTheShift() throws {
        let width = 16
        let height = 8
        let b = gaussianPlane(width: width, height: height, seed: 11)
        var a = [Double](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                a[((y + 5) % height) * width + (x + 3) % width] = b[x, y]
            }
        }
        let correlation = try XCTUnwrap(FFT.circularCrossCorrelation(a, b.values, width: width, height: height))
        let peakIndex = try XCTUnwrap(correlation.indices.max { correlation[$0] < correlation[$1] })
        XCTAssertEqual(peakIndex % width, 3)
        XCTAssertEqual(peakIndex / width, 5)
        // At the matching shift the correlation is the signal's energy.
        XCTAssertEqual(correlation[peakIndex], b.values.reduce(0) { $0 + $1 * $1 }, accuracy: 1e-9)
    }

    // MARK: - Normalized cross-correlation

    func testNormalizedCrossCorrelationKnownValues() throws {
        let a: [Double] = [1, 2, 3, 4]
        XCTAssertEqual(try XCTUnwrap(PRNUCorrelation.normalizedCrossCorrelation(a, a)), 1, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(PRNUCorrelation.normalizedCrossCorrelation(a, a.map { -2 * $0 + 7 })), -1, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(PRNUCorrelation.normalizedCrossCorrelation(a, [1, 3, 2, 4])), 0.8, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(PRNUCorrelation.normalizedCrossCorrelation([1, -1, 1, -1], [1, 1, -1, -1])), 0, accuracy: 1e-12)
    }

    func testNormalizedCrossCorrelationIsUndefinedForDegenerateInput() {
        XCTAssertNil(PRNUCorrelation.normalizedCrossCorrelation([3, 3, 3], [1, 2, 3]), "a constant vector has no variance")
        XCTAssertNil(PRNUCorrelation.normalizedCrossCorrelation([1, 2], [1, 2, 3]))
        XCTAssertNil(PRNUCorrelation.normalizedCrossCorrelation([], []))
    }

    // MARK: - Noise signatures

    func testCheckerboardSignatureAlternatesWithLagParity() throws {
        let plane = PRNUPlane(width: 12, height: 12, values: (0..<144).map { (($0 % 12) + ($0 / 12)) % 2 == 0 ? 1 : -1 })
        let signature = PRNUCorrelation.noiseSignature(of: plane, x: 2, y: 2, size: 8)
        XCTAssertEqual(signature.standardDeviation, 1, accuracy: 1e-12)
        let correlations = try XCTUnwrap(signature.lagCorrelations)
        XCTAssertEqual(correlations.count, 12)
        for (lag, value) in zip(PRNUCorrelation.signatureLags, correlations) {
            let expected: Double = abs(lag.dx + lag.dy) % 2 == 0 ? 1 : -1
            XCTAssertEqual(value, expected, accuracy: 1e-12, "lag (\(lag.dx), \(lag.dy))")
        }
    }

    func testVerticalStripeSignatureDependsOnlyOnHorizontalLag() throws {
        let plane = PRNUPlane(width: 8, height: 8, values: (0..<64).map { ($0 % 8) % 2 == 0 ? 2 : -2 })
        let signature = PRNUCorrelation.noiseSignature(of: plane, x: 0, y: 0, size: 8)
        XCTAssertEqual(signature.standardDeviation, 2, accuracy: 1e-12)
        let correlations = try XCTUnwrap(signature.lagCorrelations)
        for (lag, value) in zip(PRNUCorrelation.signatureLags, correlations) {
            XCTAssertEqual(value, abs(lag.dx) % 2 == 0 ? 1 : -1, accuracy: 1e-12, "lag (\(lag.dx), \(lag.dy))")
        }
    }

    func testWhiteNoiseSignatureIsNearZeroAtEveryLag() throws {
        let plane = gaussianPlane(width: 64, height: 64, seed: 12, scale: 3)
        let signature = PRNUCorrelation.noiseSignature(of: plane, x: 0, y: 0, size: 64)
        XCTAssertEqual(signature.standardDeviation, 3, accuracy: 0.15)
        // Sampling error on 4096 samples is about 1/64 ~ 0.016 per lag.
        for value in try XCTUnwrap(signature.lagCorrelations) {
            XCTAssertLessThan(abs(value), 0.07)
        }
    }

    func testFlatBlockHasNoSignatureAndOutOfBoundsIsSafe() {
        let flat = PRNUPlane(width: 16, height: 16, repeating: 4)
        let signature = PRNUCorrelation.noiseSignature(of: flat, x: 0, y: 0, size: 16)
        XCTAssertEqual(signature.standardDeviation, 0)
        XCTAssertNil(signature.lagCorrelations)
        XCTAssertNil(PRNUCorrelation.noiseSignature(of: flat, x: 8, y: 8, size: 16).lagCorrelations)
    }

    // MARK: - Leave-one-out medians and block consistency

    func testLeaveOneOutMediansExcludeEachElement() {
        XCTAssertEqual(PRNUCorrelation.leaveOneOutMedians([1, 2, 3, 4, 100]), [3.5, 3.5, 3, 2.5, 2.5])
        XCTAssertEqual(PRNUCorrelation.leaveOneOutMedians([5, 1, 9]), [5, 7, 3])
        XCTAssertEqual(PRNUCorrelation.leaveOneOutMedians([7]), [7])
        XCTAssertEqual(PRNUCorrelation.leaveOneOutMedians([]), [])
        XCTAssertEqual(PRNUCorrelation.median([4, 1, 3, 2]), 2.5)
        XCTAssertNil(PRNUCorrelation.median([]))
    }

    func testBlockConsistencyKnownValues() {
        let zeros = [Double](repeating: 0, count: 12)
        let identical = PRNUCorrelation.NoiseSignature(standardDeviation: 2, lagCorrelations: zeros)
        XCTAssertEqual(PRNUCorrelation.blockConsistency(identical, aggregateLagCorrelations: zeros, aggregateStandardDeviation: 2), 1, accuracy: 1e-12)

        // Worst lag off by 0.3 -> structure 0.7; level 2 vs 8 -> sqrt(0.25) = 0.5.
        var shifted = zeros
        shifted[0] = 0.3
        shifted[5] = -0.1
        XCTAssertEqual(PRNUCorrelation.blockConsistency(identical, aggregateLagCorrelations: shifted, aggregateStandardDeviation: 8), 0.35, accuracy: 1e-12)
        // The level term is symmetric: 8 vs 2 scores the same as 2 vs 8.
        let louder = PRNUCorrelation.NoiseSignature(standardDeviation: 8, lagCorrelations: zeros)
        XCTAssertEqual(PRNUCorrelation.blockConsistency(louder, aggregateLagCorrelations: shifted, aggregateStandardDeviation: 2), 0.35, accuracy: 1e-12)
    }

    func testBlockConsistencyIsZeroWithoutMeasurableNoise() {
        let zeros = [Double](repeating: 0, count: 12)
        let silent = PRNUCorrelation.NoiseSignature(standardDeviation: 0, lagCorrelations: nil)
        let normal = PRNUCorrelation.NoiseSignature(standardDeviation: 2, lagCorrelations: zeros)
        XCTAssertEqual(PRNUCorrelation.blockConsistency(silent, aggregateLagCorrelations: zeros, aggregateStandardDeviation: 2), 0)
        XCTAssertEqual(PRNUCorrelation.blockConsistency(normal, aggregateLagCorrelations: nil, aggregateStandardDeviation: 2), 0)
        XCTAssertEqual(PRNUCorrelation.blockConsistency(normal, aggregateLagCorrelations: zeros, aggregateStandardDeviation: 0), 0)
        XCTAssertEqual(PRNUCorrelation.blockConsistency(normal, aggregateLagCorrelations: [0, 0], aggregateStandardDeviation: 2), 0, "mismatched lag counts")
    }

    // MARK: - PCE

    func testPCEOfAPatternAgainstItselfIsLarge() throws {
        let pattern = gaussianPlane(width: 64, height: 64, seed: 13)
        let result = try XCTUnwrap(PRNUCorrelation.peakToCorrelationEnergy(pattern, pattern))
        XCTAssertEqual(result.peakCorrelation, 1, accuracy: 1e-9)
        // Off-peak correlations of white noise average about 1/N, so PCE
        // lands near N = 4096.
        XCTAssertGreaterThan(result.peakToCorrelationEnergy, 1000)
    }

    func testPCEOfIndependentPatternsIsBelowTheMatchThreshold() throws {
        let a = gaussianPlane(width: 64, height: 64, seed: 14)
        let b = gaussianPlane(width: 64, height: 64, seed: 15)
        let result = try XCTUnwrap(PRNUCorrelation.peakToCorrelationEnergy(a, b))
        XCTAssertLessThan(abs(result.peakCorrelation), 0.1)
        XCTAssertLessThan(abs(result.peakToCorrelationEnergy), PRNUReferenceFingerprint.matchThreshold)
    }

    func testPCEIsSignedForAnticorrelatedPatterns() throws {
        let a = gaussianPlane(width: 32, height: 32, seed: 16)
        let negated = PRNUPlane(width: 32, height: 32, values: a.values.map { -$0 })
        let result = try XCTUnwrap(PRNUCorrelation.peakToCorrelationEnergy(a, negated))
        XCTAssertEqual(result.peakCorrelation, -1, accuracy: 1e-9)
        XCTAssertLessThan(result.peakToCorrelationEnergy, 0)
    }

    func testPCEIsUndefinedForDegenerateInput() {
        let pattern = gaussianPlane(width: 32, height: 32, seed: 17)
        XCTAssertNil(PRNUCorrelation.peakToCorrelationEnergy(pattern, PRNUPlane(width: 32, height: 32, repeating: 5)), "a flat plane has no energy")
        XCTAssertNil(PRNUCorrelation.peakToCorrelationEnergy(pattern, gaussianPlane(width: 16, height: 32, seed: 18)), "sizes must match")
    }
}
