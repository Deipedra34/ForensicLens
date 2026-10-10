import Foundation

/// Robustly fits one `AffineTransform2D` to a set of point correspondences
/// that's contaminated with outliers, using RANSAC (random sample
/// consensus).
///
/// This is the step that turns "these keypoints have similar-looking
/// neighborhoods" into "this region of the image is a geometrically
/// transformed copy of that one." Descriptor matching on its own produces
/// plenty of coincidental pairs -- two unrelated corners that happen to
/// look alike -- and those land all over the image with no geometric
/// relationship to each other. A genuine clone is different: every one of
/// its matched keypoints is moved by the *same* transform. RANSAC exploits
/// exactly that. It repeatedly draws a minimal sample of three
/// correspondences, fits the affine transform they define exactly, and
/// counts how many of *all* correspondences that transform explains to
/// within `reprojectionThreshold` pixels. A transform hypothesized from
/// three coincidental matches explains almost nothing else; one hypothesized
/// from three true clone matches explains every other match of that clone.
/// The best hypothesis is then refit by least squares over its whole inlier
/// set, which averages out per-keypoint localization noise.
///
/// It knows nothing about images, keypoints, or descriptors -- just
/// points in, transform and inlier indices out -- so it can be tested
/// against synthetic correspondences with known outliers on its own.
///
/// Fully deterministic: sampling uses a seeded generator, so the same input
/// always produces the same estimate. That keeps reports reproducible and
/// tests stable, and nothing here depends on platform randomness.
public struct RANSACAffineEstimator: Sendable {
    public struct Configuration: Sendable, Equatable {
        /// Largest distance, in pixels, between a transformed source point
        /// and its target for that correspondence to count as an inlier.
        public var reprojectionThreshold: Double

        /// Fewest inliers a transform needs before it's returned at all.
        /// Below that, `estimate` returns `nil` -- no consensus.
        public var minimumInliers: Int

        /// Upper bound on the number of hypotheses drawn. The loop usually
        /// stops much earlier: once the best hypothesis's inlier ratio
        /// implies that `confidence` has been reached (the standard
        /// adaptive RANSAC stopping rule).
        public var maximumIterations: Int

        /// Desired probability (0...1, exclusive) that at least one sample
        /// was outlier-free, driving the adaptive stopping rule.
        public var confidence: Double

        /// Seed for the sampling generator.
        public var seed: UInt64

        public init(reprojectionThreshold: Double, minimumInliers: Int, maximumIterations: Int = 2000, confidence: Double = 0.995, seed: UInt64 = 0x2545_F491_4F6C_DD1D) {
            self.reprojectionThreshold = reprojectionThreshold
            self.minimumInliers = minimumInliers
            self.maximumIterations = maximumIterations
            self.confidence = confidence
            self.seed = seed
        }
    }

    /// A transform that a consensus of correspondences agreed on.
    public struct Estimate: Sendable, Equatable {
        public let transform: AffineTransform2D

        /// Indices into the input array of every correspondence the
        /// transform explains within the threshold, in ascending order.
        public let inlierIndices: [Int]
    }

    /// Below this area (in square pixels), a three-point sample is treated
    /// as degenerate (collinear or coincident) and skipped: it can't pin
    /// down an affine transform with any precision.
    private static let minimumSampleTriangleArea = 1.0

    public let configuration: Configuration

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    /// Returns the transform with the largest consensus among
    /// `correspondences`, or `nil` if no hypothesis reaches
    /// `configuration.minimumInliers` (including when there are too few
    /// correspondences to sample from at all).
    public func estimate(_ correspondences: [PointCorrespondence]) -> Estimate? {
        let count = correspondences.count
        let minimumInliers = max(3, configuration.minimumInliers)
        guard count >= minimumInliers else { return nil }

        let threshold = configuration.reprojectionThreshold.isFinite ? max(0, configuration.reprojectionThreshold) : 0
        let squaredThreshold = threshold * threshold
        let maximumIterations = max(1, configuration.maximumIterations)
        let confidence = min(0.999999, max(0.5, configuration.confidence.isFinite ? configuration.confidence : 0.995))

        var generator = SplitMix64(seed: configuration.seed)
        var bestTransform: AffineTransform2D?
        var bestCount = 0
        var requiredIterations = maximumIterations
        var iteration = 0

        while iteration < requiredIterations {
            iteration += 1

            let i = generator.nextIndex(below: count)
            let j = generator.nextIndex(below: count)
            let k = generator.nextIndex(below: count)
            guard i != j, j != k, i != k else { continue }

            let sample = [correspondences[i], correspondences[j], correspondences[k]]
            guard Self.triangleArea(sample.map(\.source)) >= Self.minimumSampleTriangleArea,
                  Self.triangleArea(sample.map(\.target)) >= Self.minimumSampleTriangleArea,
                  let hypothesis = AffineTransform2D.leastSquares(sample)
            else { continue }

            let inliers = Self.countInliers(of: hypothesis, in: correspondences, squaredThreshold: squaredThreshold)
            guard inliers > bestCount else { continue }

            bestCount = inliers
            bestTransform = hypothesis
            requiredIterations = min(maximumIterations, Self.iterationsNeeded(inlierRatio: Double(inliers) / Double(count), confidence: confidence, current: requiredIterations))
        }

        guard let roughTransform = bestTransform, bestCount >= minimumInliers else { return nil }

        // Refit over the whole consensus set, then re-score once: the
        // least-squares transform is usually more accurate than the one
        // three points defined, and can pull in a few borderline inliers.
        var transform = roughTransform
        var inliers = Self.inlierIndices(of: roughTransform, in: correspondences, squaredThreshold: squaredThreshold)
        if let refined = AffineTransform2D.leastSquares(inliers.map { correspondences[$0] }) {
            let refinedInliers = Self.inlierIndices(of: refined, in: correspondences, squaredThreshold: squaredThreshold)
            if refinedInliers.count >= inliers.count {
                transform = refined
                inliers = refinedInliers
            }
        }

        guard inliers.count >= minimumInliers else { return nil }
        return Estimate(transform: transform, inlierIndices: inliers)
    }

    private static func countInliers(of transform: AffineTransform2D, in correspondences: [PointCorrespondence], squaredThreshold: Double) -> Int {
        var inliers = 0
        for pair in correspondences where transform.apply(pair.source).squaredDistance(to: pair.target) <= squaredThreshold {
            inliers += 1
        }
        return inliers
    }

    private static func inlierIndices(of transform: AffineTransform2D, in correspondences: [PointCorrespondence], squaredThreshold: Double) -> [Int] {
        correspondences.indices.filter { transform.apply(correspondences[$0].source).squaredDistance(to: correspondences[$0].target) <= squaredThreshold }
    }

    /// The standard adaptive RANSAC bound: how many three-point samples are
    /// needed to have drawn at least one all-inlier sample with probability
    /// `confidence`, given the inlier ratio seen so far.
    private static func iterationsNeeded(inlierRatio: Double, confidence: Double, current: Int) -> Int {
        let allInlierProbability = inlierRatio * inlierRatio * inlierRatio
        guard allInlierProbability > 0 else { return current }
        guard allInlierProbability < 1 else { return 1 }
        let needed = log(1 - confidence) / log(1 - allInlierProbability)
        guard needed.isFinite else { return current }
        return max(1, Int(needed.rounded(.up)))
    }

    private static func triangleArea(_ points: [Point2D]) -> Double {
        guard points.count == 3 else { return 0 }
        let (p, q, r) = (points[0], points[1], points[2])
        return abs((q.x - p.x) * (r.y - p.y) - (r.x - p.x) * (q.y - p.y)) / 2
    }
}

/// SplitMix64: a tiny, fast, well-distributed 64-bit generator. Used instead
/// of `SystemRandomNumberGenerator` so feature matching is reproducible, and
/// instead of a plain LCG because an LCG's low bits cycle with very short
/// periods -- sampling `next() % n` from one would correlate consecutive
/// indices (e.g. alternate their parity), which RANSAC's sampling can't
/// tolerate.
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A value in `0..<bound`, taken from the high bits. `bound` must be
    /// positive.
    mutating func nextIndex(below bound: Int) -> Int {
        Int((next() >> 11) % UInt64(bound))
    }

    /// A uniformly distributed value in `[0, 1)`.
    mutating func nextUnitInterval() -> Double {
        Double(next() >> 11) / Double(UInt64(1) << 53)
    }
}
