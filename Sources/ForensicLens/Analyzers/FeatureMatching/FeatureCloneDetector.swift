import Foundation
import ImageDecoding

/// One duplicated-region pair confirmed by feature matching: `target` is a
/// copy of `source` under `transform`.
public struct FeatureClonePair: Sendable, Equatable {
    /// Bounding box of the matched keypoints in the region treated as the
    /// original, padded slightly to cover their neighborhoods. Which side
    /// is called the "source" is a convention, not a claim about which
    /// region the forger copied from -- that can't be told from geometry
    /// alone. The region that comes first in reading order (top-to-bottom,
    /// then left-to-right) is always the source, so reports are stable.
    public let source: Region

    /// Bounding box of the matched keypoints in the duplicated region.
    public let target: Region

    /// Maps points in `source` onto their counterparts in `target`.
    public let transform: AffineTransform2D

    /// Rotation between the two regions, in degrees within `(-180, 180]`,
    /// positive clockwise on screen (image `y` axis points down).
    public var rotationDegrees: Double { transform.rotationDegrees }

    /// Scale factor from `source` to `target` (above 1: the copy was
    /// enlarged).
    public var scale: Double { transform.scale }

    /// Number of distinct keypoint matches consistent with `transform`.
    public let inlierCount: Int
}

/// The outcome of one feature-matching pass, including *why* nothing was
/// found when that's the case.
public struct FeatureCloneDetectionResult: Sendable, Equatable {
    public enum Outcome: String, Sendable, Equatable {
        /// At least one clone pair was confirmed.
        case cloneDetected

        /// Too few keypoints to possibly confirm a clone (flat, tiny, or
        /// featureless image).
        case tooFewKeypoints

        /// Keypoints were found, but not enough distinctive descriptor
        /// matches between them.
        case noDescriptorMatches

        /// Descriptor matches were found, but no geometric transform was
        /// consistent with enough of them -- they were coincidental.
        case noConsistentTransform
    }

    public let outcome: Outcome
    public let keypointCount: Int
    public let matchCount: Int
    public let pairs: [FeatureClonePair]

    /// A one-line, human-readable explanation of this result.
    public var summary: String {
        switch outcome {
        case .cloneDetected:
            return "\(pairs.count) rotation/scale-tolerant clone pair(s) confirmed by feature matching."
        case .tooFewKeypoints:
            return "No clone detected via feature matching: only \(keypointCount) keypoint(s) found, too few to confirm a duplicated region."
        case .noDescriptorMatches:
            return "No clone detected via feature matching: \(keypointCount) keypoint(s) found, but only \(matchCount) distinctive descriptor match(es) between them."
        case .noConsistentTransform:
            return "No clone detected via feature matching: \(matchCount) descriptor match(es) found, but no single geometric transform explains enough of them."
        }
    }
}

/// Finds copy-move forgeries whose pasted patch was rotated and/or rescaled
/// -- the case `CloneDetectionAnalyzer`'s block matching can't see, since a
/// rotated or rescaled block no longer looks like its source block
/// pixel-for-pixel.
///
/// Three independent stages, each in its own type:
///
/// 1. `FeatureExtractor` finds corner keypoints across a scale pyramid and
///    gives each an orientation and a rotation-steered binary descriptor,
///    so the same physical corner gets (nearly) the same descriptor in a
///    rotated or rescaled copy.
/// 2. `DescriptorMatcher` matches the image's keypoints against each other.
/// 3. `RANSACAffineEstimator` looks for one affine transform that a large
///    group of those matches agrees on, and rejects the rest as
///    coincidences. A confirmed transform yields a clone pair plus the
///    rotation and scale between its two regions. It runs repeatedly,
///    removing each confirmed pair's matches, to find several independent
///    clones in one image.
///
/// Matches are undirected (the matcher doesn't know which end is the
/// original), so each one is given to RANSAC in both directions. A real
/// clone's matches agree on transform `T` in one direction and on `T`'s
/// inverse in the other; whichever RANSAC finds first, both directions of
/// its matches are retired together, so a pair is never reported twice.
public struct FeatureCloneDetector: Sendable {
    public struct Settings: Sendable, Equatable {
        /// Fewest distinct keypoint matches that must agree on one
        /// transform to confirm a clone pair.
        public var minimumMatchedKeypoints: Int

        /// RANSAC inlier threshold, in pixels.
        public var reprojectionThreshold: Double

        /// Cap on keypoints extracted per image.
        public var maximumKeypoints: Int

        /// Matched keypoints closer together than this, in pixels, are
        /// ignored (a corner trivially resembles itself and its neighbors).
        public var minimumMatchDistance: Double

        public init(minimumMatchedKeypoints: Int, reprojectionThreshold: Double, maximumKeypoints: Int, minimumMatchDistance: Double) {
            self.minimumMatchedKeypoints = minimumMatchedKeypoints
            self.reprojectionThreshold = reprojectionThreshold
            self.maximumKeypoints = maximumKeypoints
            self.minimumMatchDistance = minimumMatchDistance
        }

        public init(_ config: ForensicLensConfig.CloneDetectionConfig) {
            self.init(
                minimumMatchedKeypoints: config.minimumMatchedKeypoints,
                reprojectionThreshold: config.ransacReprojectionThreshold,
                maximumKeypoints: config.maximumKeypoints,
                minimumMatchDistance: Double(config.minimumBlockDistance)
            )
        }

        // Out-of-range values from a hand-edited config fall back to safe
        // bounds rather than disabling the search or trapping.
        var sanitizedMinimumMatches: Int { max(3, minimumMatchedKeypoints) }
        var sanitizedThreshold: Double { reprojectionThreshold.isFinite && reprojectionThreshold > 0 ? reprojectionThreshold : 3 }
        var sanitizedMaximumKeypoints: Int { max(1, maximumKeypoints) }
        var sanitizedMinimumDistance: Double { minimumMatchDistance.isFinite ? max(1, minimumMatchDistance) : 24 }
    }

    /// Clone pairs reported per image, at most.
    static let maximumClonePairs = 8

    /// A confirmed transform must be a plausible copy-paste edit: scaled by
    /// no more than this factor either way...
    static let maximumScaleChange = 3.0

    /// ...and not stretched much more in one direction than another.
    /// Coincidental matches that RANSAC manages to fit tend to produce
    /// wildly sheared or mirrored transforms; a real rotate/scale edit
    /// stays close to a similarity.
    static let maximumAnisotropy = 1.5

    /// Padding, in pixels, around matched keypoints when sizing a region:
    /// keypoints sit inside the copied patch, not on its edge.
    static let regionMargin = 8.0

    public let settings: Settings

    public init(settings: Settings) {
        self.settings = settings
    }

    /// Runs the full extract-match-verify pipeline on `buffer`.
    public func detect(in buffer: PixelBuffer) -> FeatureCloneDetectionResult {
        let keypoints = FeatureExtractor.extract(from: buffer, maximumKeypoints: settings.sanitizedMaximumKeypoints)
        return detect(keypoints: keypoints, imageWidth: buffer.width, imageHeight: buffer.height)
    }

    /// Runs matching and geometric verification on keypoints that were
    /// already extracted -- what `TiledCloneDetection` uses after pooling
    /// keypoints from every tile into one image-wide set.
    func detect(keypoints: [Keypoint], imageWidth: Int, imageHeight: Int) -> FeatureCloneDetectionResult {
        let minimumMatches = settings.sanitizedMinimumMatches
        // Every match needs a keypoint on each side of the clone.
        guard keypoints.count >= 2 * minimumMatches else {
            return FeatureCloneDetectionResult(outcome: .tooFewKeypoints, keypointCount: keypoints.count, matchCount: 0, pairs: [])
        }

        let matches = DescriptorMatcher.selfMatches(keypoints, minimumSpatialDistance: settings.sanitizedMinimumDistance)
        guard matches.count >= minimumMatches else {
            return FeatureCloneDetectionResult(outcome: .noDescriptorMatches, keypointCount: keypoints.count, matchCount: matches.count, pairs: [])
        }

        let estimator = RANSACAffineEstimator(configuration: .init(
            reprojectionThreshold: settings.sanitizedThreshold,
            minimumInliers: minimumMatches
        ))

        var remaining = Array(matches.indices)
        var pairs: [FeatureClonePair] = []
        var attempts = 0

        while pairs.count < Self.maximumClonePairs, attempts < 2 * Self.maximumClonePairs, remaining.count >= minimumMatches {
            attempts += 1

            var correspondences: [PointCorrespondence] = []
            var matchIDs: [Int] = []
            correspondences.reserveCapacity(remaining.count * 2)
            matchIDs.reserveCapacity(remaining.count * 2)
            for id in remaining {
                let p = keypoints[matches[id].first].position
                let q = keypoints[matches[id].second].position
                correspondences.append(PointCorrespondence(source: p, target: q))
                correspondences.append(PointCorrespondence(source: q, target: p))
                matchIDs.append(id)
                matchIDs.append(id)
            }

            guard let estimate = estimator.estimate(correspondences) else { break }

            let consensus = Set(estimate.inlierIndices.map { matchIDs[$0] })
            remaining.removeAll { consensus.contains($0) }

            let endpoints = consensus.sorted().map { id in
                (keypoints[matches[id].first].position, keypoints[matches[id].second].position)
            }
            guard endpoints.count >= minimumMatches,
                  let pair = makePair(endpoints: endpoints, imageWidth: imageWidth, imageHeight: imageHeight)
            else { continue }
            pairs.append(pair)
        }

        return FeatureCloneDetectionResult(
            outcome: pairs.isEmpty ? .noConsistentTransform : .cloneDetected,
            keypointCount: keypoints.count,
            matchCount: matches.count,
            pairs: pairs
        )
    }

    /// Turns a consensus set of matches into a reported pair: orients every
    /// match the same way, refits the transform over all of them, checks
    /// it's a plausible edit, and boxes each side.
    private func makePair(endpoints: [(Point2D, Point2D)], imageWidth: Int, imageHeight: Int) -> FeatureClonePair? {
        guard let anchor = endpoints.first else { return nil }

        // Orient each match so its first point lies on the same side as the
        // anchor's. RANSAC's own inlier directions can't be trusted for
        // this: a clone rotated by exactly 180 degrees is its own inverse,
        // so both directions of every match fit the same transform.
        let oriented: [PointCorrespondence] = endpoints.map { endpoint in
            let (p, q) = endpoint
            let straight = p.squaredDistance(to: anchor.0) + q.squaredDistance(to: anchor.1)
            let swapped = q.squaredDistance(to: anchor.0) + p.squaredDistance(to: anchor.1)
            return straight <= swapped ? PointCorrespondence(source: p, target: q) : PointCorrespondence(source: q, target: p)
        }

        guard var transform = AffineTransform2D.leastSquares(oriented) else { return nil }
        var source = Self.boundingRegion(oriented.map(\.source), imageWidth: imageWidth, imageHeight: imageHeight)
        var target = Self.boundingRegion(oriented.map(\.target), imageWidth: imageWidth, imageHeight: imageHeight)

        if (target.y, target.x) < (source.y, source.x) {
            guard let inverse = transform.inverse else { return nil }
            transform = inverse
            swap(&source, &target)
        }

        guard Self.isPlausibleEdit(transform) else { return nil }
        return FeatureClonePair(source: source, target: target, transform: transform, inlierCount: oriented.count)
    }

    static func isPlausibleEdit(_ transform: AffineTransform2D) -> Bool {
        let scale = transform.scale
        return transform.determinant > 0
            && scale.isFinite
            && scale >= 1 / maximumScaleChange
            && scale <= maximumScaleChange
            && transform.anisotropy <= maximumAnisotropy
    }

    static func boundingRegion(_ points: [Point2D], imageWidth: Int, imageHeight: Int) -> Region {
        var minX = Double.infinity, minY = Double.infinity
        var maxX = -Double.infinity, maxY = -Double.infinity
        for point in points {
            minX = min(minX, point.x)
            minY = min(minY, point.y)
            maxX = max(maxX, point.x)
            maxY = max(maxY, point.y)
        }
        guard minX.isFinite, minY.isFinite, maxX.isFinite, maxY.isFinite else {
            return Region(x: 0, y: 0, width: 0, height: 0)
        }
        let x0 = max(0, Int((minX - regionMargin).rounded(.down)))
        let y0 = max(0, Int((minY - regionMargin).rounded(.down)))
        let x1 = min(imageWidth, Int((maxX + regionMargin).rounded(.up)) + 1)
        let y1 = min(imageHeight, Int((maxY + regionMargin).rounded(.up)) + 1)
        return Region(x: x0, y: y0, width: max(1, x1 - x0), height: max(1, y1 - y0))
    }
}
