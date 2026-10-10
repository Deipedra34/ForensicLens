import XCTest
import ForensicLens

/// Exercises `RANSACAffineEstimator` and `AffineTransform2D` on their own,
/// with synthetic point correspondences -- no images, keypoints, or
/// descriptors involved -- so a failure here points squarely at geometric
/// verification rather than anything upstream of it.
final class RANSACAffineEstimatorTests: XCTestCase {
    // MARK: - Synthetic correspondences

    /// A deterministic uniform value in `range`.
    private func uniform(_ generator: inout Fixtures.SeededGenerator, in range: ClosedRange<Double>) -> Double {
        let unit = Double(generator.next() >> 11) / Double(UInt64(1) << 53)
        return range.lowerBound + unit * (range.upperBound - range.lowerBound)
    }

    /// `count` source points spread over a grid-like patch, each mapped
    /// through `transform` with up to `jitter` pixels of localization noise
    /// on the target -- what real keypoint matches of one clone look like.
    private func inliers(count: Int, of transform: AffineTransform2D, jitter: Double, generator: inout Fixtures.SeededGenerator) -> [PointCorrespondence] {
        (0..<count).map { index in
            let source = Point2D(
                x: 20 + Double(index % 6) * 9 + uniform(&generator, in: -2...2),
                y: 30 + Double(index / 6) * 9 + uniform(&generator, in: -2...2)
            )
            let exact = transform.apply(source)
            let target = Point2D(x: exact.x + uniform(&generator, in: -jitter...jitter), y: exact.y + uniform(&generator, in: -jitter...jitter))
            return PointCorrespondence(source: source, target: target)
        }
    }

    /// `count` coincidental matches: arbitrary pairs of points with no
    /// geometric relationship, each guaranteed to land well away from
    /// where `transform` would put its source.
    private func outliers(count: Int, awayFrom transform: AffineTransform2D, generator: inout Fixtures.SeededGenerator) -> [PointCorrespondence] {
        var result: [PointCorrespondence] = []
        while result.count < count {
            let source = Point2D(x: uniform(&generator, in: 0...400), y: uniform(&generator, in: 0...400))
            let target = Point2D(x: uniform(&generator, in: 0...400), y: uniform(&generator, in: 0...400))
            let predicted = transform.apply(source)
            let dx = predicted.x - target.x
            let dy = predicted.y - target.y
            guard (dx * dx + dy * dy).squareRoot() > 20 else { continue }
            result.append(PointCorrespondence(source: source, target: target))
        }
        return result
    }

    /// Interleaves inliers and outliers deterministically, returning the
    /// combined list and the indices at which the inliers ended up.
    private func interleave(_ inliers: [PointCorrespondence], _ outliers: [PointCorrespondence]) -> (all: [PointCorrespondence], inlierIndices: [Int]) {
        var all: [PointCorrespondence] = []
        var inlierIndices: [Int] = []
        var i = 0
        var o = 0
        while i < inliers.count || o < outliers.count {
            if o < outliers.count {
                all.append(outliers[o])
                o += 1
            }
            if i < inliers.count {
                inlierIndices.append(all.count)
                all.append(inliers[i])
                i += 1
            }
        }
        return (all, inlierIndices)
    }

    private let configuration = RANSACAffineEstimator.Configuration(reprojectionThreshold: 3, minimumInliers: 8)

    // MARK: - Recovering the transform

    func testRecoversRotationAndScaleAndRejectsPlantedOutliers() throws {
        var generator = Fixtures.SeededGenerator(seed: 11)
        let truth = AffineTransform2D.similarity(rotationDegrees: 25, scale: 1.3, tx: 180, ty: 60)
        let good = inliers(count: 40, of: truth, jitter: 0.5, generator: &generator)
        let bad = outliers(count: 25, awayFrom: truth, generator: &generator)
        let (correspondences, expectedInliers) = interleave(good, bad)

        let estimate = try XCTUnwrap(RANSACAffineEstimator(configuration: configuration).estimate(correspondences))

        XCTAssertEqual(estimate.inlierIndices, expectedInliers, "every planted outlier must be rejected and every true match kept")
        XCTAssertEqual(estimate.transform.rotationDegrees, 25, accuracy: 0.5)
        XCTAssertEqual(estimate.transform.scale, 1.3, accuracy: 0.01)
        XCTAssertEqual(estimate.transform.tx, truth.tx, accuracy: 1.5)
        XCTAssertEqual(estimate.transform.ty, truth.ty, accuracy: 1.5)
    }

    func testRecoversTransformEvenWhenOutliersOutnumberInliers() throws {
        var generator = Fixtures.SeededGenerator(seed: 23)
        let truth = AffineTransform2D.similarity(rotationDegrees: -70, scale: 0.75, tx: 250, ty: 210)
        let good = inliers(count: 18, of: truth, jitter: 0.5, generator: &generator)
        let bad = outliers(count: 48, awayFrom: truth, generator: &generator)
        let (correspondences, expectedInliers) = interleave(good, bad)

        let estimate = try XCTUnwrap(RANSACAffineEstimator(configuration: configuration).estimate(correspondences))

        XCTAssertEqual(estimate.inlierIndices, expectedInliers)
        XCTAssertEqual(estimate.transform.rotationDegrees, -70, accuracy: 1.5)
        XCTAssertEqual(estimate.transform.scale, 0.75, accuracy: 0.02)
    }

    func testRecoversGeneralAffineTransformExactlyWithoutNoise() throws {
        var generator = Fixtures.SeededGenerator(seed: 5)
        // Non-uniform scale plus shear: not a similarity, but still affine.
        let truth = AffineTransform2D(a: 1.1, b: 0.2, tx: -15, c: -0.1, d: 0.9, ty: 140)
        let good = inliers(count: 24, of: truth, jitter: 0, generator: &generator)
        let bad = outliers(count: 10, awayFrom: truth, generator: &generator)
        let (correspondences, expectedInliers) = interleave(good, bad)

        let estimate = try XCTUnwrap(RANSACAffineEstimator(configuration: configuration).estimate(correspondences))

        XCTAssertEqual(estimate.inlierIndices, expectedInliers)
        XCTAssertEqual(estimate.transform.a, truth.a, accuracy: 1e-6)
        XCTAssertEqual(estimate.transform.b, truth.b, accuracy: 1e-6)
        XCTAssertEqual(estimate.transform.c, truth.c, accuracy: 1e-6)
        XCTAssertEqual(estimate.transform.d, truth.d, accuracy: 1e-6)
        XCTAssertEqual(estimate.transform.tx, truth.tx, accuracy: 1e-4)
        XCTAssertEqual(estimate.transform.ty, truth.ty, accuracy: 1e-4)
    }

    func testRecoversPureTranslation() throws {
        var generator = Fixtures.SeededGenerator(seed: 2)
        let truth = AffineTransform2D(a: 1, b: 0, tx: 96, c: 0, d: 1, ty: -12)
        let good = inliers(count: 18, of: truth, jitter: 0.3, generator: &generator)
        let bad = outliers(count: 12, awayFrom: truth, generator: &generator)
        let (correspondences, expectedInliers) = interleave(good, bad)

        let estimate = try XCTUnwrap(RANSACAffineEstimator(configuration: configuration).estimate(correspondences))

        XCTAssertEqual(estimate.inlierIndices, expectedInliers)
        XCTAssertEqual(estimate.transform.rotationDegrees, 0, accuracy: 1)
        XCTAssertEqual(estimate.transform.scale, 1, accuracy: 0.01)
    }

    func testEstimateIsDeterministic() {
        var generator = Fixtures.SeededGenerator(seed: 11)
        let truth = AffineTransform2D.similarity(rotationDegrees: 40, scale: 1.1, tx: 100, ty: 100)
        let good = inliers(count: 20, of: truth, jitter: 0.5, generator: &generator)
        let bad = outliers(count: 30, awayFrom: truth, generator: &generator)
        let (correspondences, _) = interleave(good, bad)
        let estimator = RANSACAffineEstimator(configuration: configuration)

        XCTAssertEqual(estimator.estimate(correspondences), estimator.estimate(correspondences))
    }

    // MARK: - No consensus

    func testUnrelatedCorrespondencesYieldNoEstimate() {
        var generator = Fixtures.SeededGenerator(seed: 99)
        let random = (0..<60).map { _ in
            PointCorrespondence(
                source: Point2D(x: uniform(&generator, in: 0...500), y: uniform(&generator, in: 0...500)),
                target: Point2D(x: uniform(&generator, in: 0...500), y: uniform(&generator, in: 0...500))
            )
        }

        XCTAssertNil(RANSACAffineEstimator(configuration: configuration).estimate(random))
    }

    func testTooFewCorrespondencesYieldNoEstimateRatherThanCrashing() {
        let estimator = RANSACAffineEstimator(configuration: configuration)
        XCTAssertNil(estimator.estimate([]))
        XCTAssertNil(estimator.estimate([PointCorrespondence(source: Point2D(x: 0, y: 0), target: Point2D(x: 5, y: 5))]))

        let truth = AffineTransform2D.similarity(rotationDegrees: 10, scale: 1, tx: 50, ty: 0)
        var generator = Fixtures.SeededGenerator(seed: 4)
        let tooFew = inliers(count: 7, of: truth, jitter: 0, generator: &generator)
        XCTAssertNil(estimator.estimate(tooFew), "seven perfect matches are still below minimumInliers (8)")
    }

    func testCollinearSourcePointsYieldNoEstimate() {
        // Every source on one line leaves the transform underdetermined
        // perpendicular to it, so every sample is degenerate.
        let collinear = (0..<20).map { index in
            PointCorrespondence(source: Point2D(x: Double(index) * 5, y: 10), target: Point2D(x: Double(index) * 5 + 100, y: 40))
        }
        XCTAssertNil(RANSACAffineEstimator(configuration: configuration).estimate(collinear))
    }

    // MARK: - AffineTransform2D

    func testLeastSquaresFitsThreePointsExactly() throws {
        let truth = AffineTransform2D(a: 0.8, b: -0.3, tx: 12, c: 0.4, d: 1.2, ty: -7)
        let sources = [Point2D(x: 0, y: 0), Point2D(x: 30, y: 4), Point2D(x: 8, y: 25)]
        let fitted = try XCTUnwrap(AffineTransform2D.leastSquares(sources.map { PointCorrespondence(source: $0, target: truth.apply($0)) }))

        XCTAssertEqual(fitted.a, truth.a, accuracy: 1e-9)
        XCTAssertEqual(fitted.b, truth.b, accuracy: 1e-9)
        XCTAssertEqual(fitted.c, truth.c, accuracy: 1e-9)
        XCTAssertEqual(fitted.d, truth.d, accuracy: 1e-9)
        XCTAssertEqual(fitted.tx, truth.tx, accuracy: 1e-9)
        XCTAssertEqual(fitted.ty, truth.ty, accuracy: 1e-9)
    }

    func testLeastSquaresRejectsCollinearAndUndersizedInput() {
        let line = [0.0, 10, 20].map { PointCorrespondence(source: Point2D(x: $0, y: $0), target: Point2D(x: $0, y: 0)) }
        XCTAssertNil(AffineTransform2D.leastSquares(line))
        XCTAssertNil(AffineTransform2D.leastSquares(Array(line.prefix(2))))
    }

    func testSimilarityDecomposesIntoItsRotationAndScale() {
        let transform = AffineTransform2D.similarity(rotationDegrees: -135, scale: 2.5, tx: 3, ty: 4)
        XCTAssertEqual(transform.rotationDegrees, -135, accuracy: 1e-9)
        XCTAssertEqual(transform.scale, 2.5, accuracy: 1e-9)
        XCTAssertEqual(transform.anisotropy, 1, accuracy: 1e-9)

        let sheared = AffineTransform2D(a: 1, b: 0.5, tx: 0, c: 0, d: 1, ty: 0)
        XCTAssertGreaterThan(sheared.anisotropy, 1.5)
    }

    func testInverseUndoesTheTransform() throws {
        let transform = AffineTransform2D.similarity(rotationDegrees: 33, scale: 0.7, tx: -40, ty: 18)
        let inverse = try XCTUnwrap(transform.inverse)
        let point = Point2D(x: 123.5, y: -7.25)
        let roundTrip = inverse.apply(transform.apply(point))

        XCTAssertEqual(roundTrip.x, point.x, accuracy: 1e-9)
        XCTAssertEqual(roundTrip.y, point.y, accuracy: 1e-9)
        XCTAssertEqual(inverse.rotationDegrees, -33, accuracy: 1e-9)
        XCTAssertEqual(inverse.scale, 1 / 0.7, accuracy: 1e-9)

        XCTAssertNil(AffineTransform2D(a: 1, b: 2, tx: 0, c: 2, d: 4, ty: 0).inverse, "a singular transform has no inverse")
    }
}
