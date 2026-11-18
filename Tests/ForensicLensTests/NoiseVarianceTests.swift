import XCTest
@testable import ForensicLens

/// The noise-level check's two smallest units, on inputs whose answer is
/// known exactly: `NoiseResidual.highPass` (Immerkaer's mask) and the two
/// `NoiseVariance` estimates built on it.
final class NoiseVarianceTests: XCTestCase {
    private func plane(width: Int, height: Int, _ value: (Int, Int) -> Double) -> PRNUPlane {
        var values = [Double](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                values[y * width + x] = value(x, y)
            }
        }
        return PRNUPlane(width: width, height: height, values: values)
    }

    // MARK: - High-pass residual

    func testResidualDropsTheOuterBorder() {
        let residual = NoiseResidual.highPass(plane(width: 10, height: 7) { _, _ in 0 })
        XCTAssertEqual(residual.width, 8)
        XCTAssertEqual(residual.height, 5)
        XCTAssertEqual(residual.values.count, 40)
    }

    func testResidualOfTooSmallPlaneIsEmpty() {
        XCTAssertEqual(NoiseResidual.highPass(plane(width: 2, height: 9) { _, _ in 1 }).values, [])
        XCTAssertEqual(NoiseResidual.highPass(PRNUPlane(width: 0, height: 0)).values, [])
    }

    func testResidualCancelsFlatAreasAndLinearGradients() {
        for content in [
            { (_: Int, _: Int) in 128.0 },
            { (x: Int, _: Int) in 10 + 3.5 * Double(x) },
            { (x: Int, y: Int) in 200 - 2 * Double(x) + 0.75 * Double(y) },
            { (x: Int, _: Int) in Double(x * x) }, // curved along one axis only
        ] {
            let residual = NoiseResidual.highPass(plane(width: 12, height: 12, content))
            XCTAssertTrue(residual.values.allSatisfy { abs($0) < 1e-9 }, "\(residual.values.prefix(4))")
        }
    }

    func testResidualOfASingleSpikeIsTheMaskItself() {
        let spike = plane(width: 5, height: 5) { x, y in x == 2 && y == 2 ? 1 : 0 }
        // Each output pixel sees the spike at a different mask position, so
        // the 3x3 output is the mask, mirrored (it's symmetric anyway).
        XCTAssertEqual(NoiseResidual.highPass(spike).values, NoiseResidual.mask)
    }

    func testMaskNormMatchesTheCoefficients() {
        let sumOfSquares = NoiseResidual.mask.reduce(0) { $0 + $1 * $1 }
        XCTAssertEqual(NoiseResidual.maskNorm * NoiseResidual.maskNorm, sumOfSquares)
    }

    // MARK: - Variance estimates

    func testCheckerboardHasAnExactlyKnownVariance() throws {
        // +-a alternating: every interior pixel's response is +-16a.
        let a = 3.0
        let board = plane(width: 16, height: 16) { x, y in (x + y) % 2 == 0 ? a : -a }
        let residual = NoiseResidual.highPass(board).values
        XCTAssertTrue(residual.allSatisfy { abs(abs($0) - 16 * a) < 1e-9 })

        XCTAssertEqual(try XCTUnwrap(NoiseVariance.energyVariance(of: residual)), 256 * a * a / 36, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(NoiseVariance.robustSigma(of: residual)), NoiseVariance.madToSigma * 16 * a / 6, accuracy: 1e-9)
    }

    func testEnergyVarianceOfKnownValues() throws {
        // r = [6, -6, 12, 0]: mean square (36 + 36 + 144 + 0) / 4 = 54,
        // over maskNorm^2 = 36 gives 1.5.
        XCTAssertEqual(try XCTUnwrap(NoiseVariance.energyVariance(of: [6, -6, 12, 0])), 1.5, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(NoiseVariance.energyVariance(of: [0, 0, 0])), 0)
    }

    func testRobustSigmaIgnoresAMinorityOfOutliers() throws {
        // Median |r| is 6 whatever the two huge values are.
        let clean = try XCTUnwrap(NoiseVariance.robustSigma(of: [6, -6, 6, -6, 6]))
        let withEdges = try XCTUnwrap(NoiseVariance.robustSigma(of: [6, -6, 6, -900, 4000]))
        XCTAssertEqual(clean, NoiseVariance.madToSigma, accuracy: 1e-12)
        XCTAssertEqual(withEdges, clean, accuracy: 1e-12)
        // The mean-square estimate, by contrast, is dominated by them.
        XCTAssertGreaterThan(try XCTUnwrap(NoiseVariance.energyVariance(of: [6, -6, 6, -900, 4000])), 10_000)
    }

    func testEmptyResidualIsUnmeasuredNotNoiseless() {
        XCTAssertNil(NoiseVariance.energyVariance(of: []))
        XCTAssertNil(NoiseVariance.robustSigma(of: []))
    }

    func testGaussianNoiseIsRecoveredByBothEstimates() throws {
        for sigma in [1.0, 4.0, 10.0] {
            var generator = Fixtures.SeededGenerator(seed: 41)
            let noisy = plane(width: 200, height: 200) { x, y in
                // A gradient underneath, which the mask removes.
                100 + 0.2 * Double(x) - 0.1 * Double(y) + sigma * Fixtures.nextGaussian(&generator)
            }
            let residual = NoiseResidual.highPass(noisy).values
            let variance = try XCTUnwrap(NoiseVariance.energyVariance(of: residual))
            let robust = try XCTUnwrap(NoiseVariance.robustSigma(of: residual))
            XCTAssertEqual(variance.squareRoot(), sigma, accuracy: sigma * 0.03, "energy estimate for sigma \(sigma)")
            XCTAssertEqual(robust, sigma, accuracy: sigma * 0.05, "robust estimate for sigma \(sigma)")
        }
    }

    // MARK: - Selection median

    func testSelectionMedianMatchesASortedMedian() throws {
        var generator = Fixtures.SeededGenerator(seed: 77)
        for count in [1, 2, 3, 4, 5, 10, 63, 64, 4096, 4097] {
            for distinct in [3, 1000] { // few distinct values (8-bit residuals) and many
                let values = (0..<count).map { _ in Double(generator.next() % UInt64(distinct)) }
                var scratch = values
                let expected = try XCTUnwrap(PRNUCorrelation.median(values))
                XCTAssertEqual(try XCTUnwrap(NoiseVariance.median(selectingIn: &scratch)), expected, "count \(count), distinct \(distinct)")
                XCTAssertEqual(scratch.sorted(), values.sorted(), "only reordered")
            }
        }
    }

    func testSelectionMedianOfConstantAndSortedRuns() {
        var zeros = [Double](repeating: 0, count: 4096)
        XCTAssertEqual(NoiseVariance.median(selectingIn: &zeros), 0)
        var ascending = (0..<1001).map(Double.init)
        XCTAssertEqual(NoiseVariance.median(selectingIn: &ascending), 500)
        var descending = (0..<1000).reversed().map(Double.init)
        XCTAssertEqual(NoiseVariance.median(selectingIn: &descending), 499.5)
        var empty: [Double] = []
        XCTAssertNil(NoiseVariance.median(selectingIn: &empty))
    }
}

