import Foundation

/// A point in image pixel coordinates (origin at the top-left, `x` to the
/// right, `y` down), with sub-pixel precision.
public struct Point2D: Sendable, Hashable, Codable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    func squaredDistance(to other: Point2D) -> Double {
        let dx = x - other.x
        let dy = y - other.y
        return dx * dx + dy * dy
    }
}

/// One putative correspondence: a point in one region of the image and the
/// point it's believed to have been copied to.
public struct PointCorrespondence: Sendable, Hashable {
    public let source: Point2D
    public let target: Point2D

    public init(source: Point2D, target: Point2D) {
        self.source = source
        self.target = target
    }
}

/// A 2D affine transform mapping `(x, y)` to
/// `(a*x + b*y + tx, c*x + d*y + ty)`.
///
/// Affine (six degrees of freedom) rather than a similarity (four) or a
/// homography (eight): it covers everything a copy-move forger can do with
/// an ordinary editor's transform handles -- move, rotate, uniform or
/// non-uniform scale, a little shear -- while staying linear, so a
/// three-point minimal sample pins it down exactly and a least-squares
/// refit over every inlier is a closed-form 2x2 solve. A homography's
/// perspective terms would buy nothing for a flat patch pasted back into
/// the same photo, and would make RANSAC's minimal sample four points.
///
/// Named with a `2D` suffix because Foundation already exports an
/// `AffineTransform`; reusing that name would make it ambiguous in any
/// file that imports both Foundation and ForensicLens.
public struct AffineTransform2D: Sendable, Equatable, Codable {
    public let a: Double
    public let b: Double
    public let tx: Double
    public let c: Double
    public let d: Double
    public let ty: Double

    public init(a: Double, b: Double, tx: Double, c: Double, d: Double, ty: Double) {
        self.a = a
        self.b = b
        self.tx = tx
        self.c = c
        self.d = d
        self.ty = ty
    }

    /// A rotation by `rotationDegrees` and uniform scale by `scale` about
    /// the origin, followed by a translation of `(tx, ty)`. Angles follow
    /// image coordinates (`y` down), so a positive angle turns clockwise
    /// on screen.
    public static func similarity(rotationDegrees: Double, scale: Double, tx: Double, ty: Double) -> AffineTransform2D {
        let theta = rotationDegrees * Double.pi / 180
        let cosine = cos(theta) * scale
        let sine = sin(theta) * scale
        return AffineTransform2D(a: cosine, b: -sine, tx: tx, c: sine, d: cosine, ty: ty)
    }

    public func apply(_ point: Point2D) -> Point2D {
        Point2D(x: a * point.x + b * point.y + tx, y: c * point.x + d * point.y + ty)
    }

    public var determinant: Double {
        a * d - b * c
    }

    /// The rotation of the closest similarity transform, in degrees within
    /// `(-180, 180]`. Exact for a pure rotation + uniform scale; for a
    /// sheared transform it's the rotation that best explains it.
    public var rotationDegrees: Double {
        atan2(c - b, a + d) * 180 / Double.pi
    }

    /// The uniform scale factor: the square root of the area ratio
    /// (`|determinant|`). Exact for a similarity transform.
    public var scale: Double {
        abs(determinant).squareRoot()
    }

    /// The ratio between the largest and smallest stretch this transform
    /// applies in any direction (its singular values). 1 for a pure
    /// rotation + uniform scale; grows with shear or non-uniform scaling,
    /// and is infinite for a degenerate (collapsing) transform.
    public var anisotropy: Double {
        let e = (a + d) / 2
        let f = (a - d) / 2
        let g = (c + b) / 2
        let h = (c - b) / 2
        let q = (e * e + h * h).squareRoot()
        let r = (f * f + g * g).squareRoot()
        let smallest = abs(q - r)
        guard smallest > 1e-12 else { return .infinity }
        return (q + r) / smallest
    }

    /// The transform mapping every target point back onto its source, or
    /// `nil` if this transform collapses the plane and has no inverse.
    public var inverse: AffineTransform2D? {
        let det = determinant
        guard abs(det) > 1e-12, det.isFinite else { return nil }
        let ia = d / det
        let ib = -b / det
        let ic = -c / det
        let id = a / det
        return AffineTransform2D(a: ia, b: ib, tx: -(ia * tx + ib * ty), c: ic, d: id, ty: -(ic * tx + id * ty))
    }

    /// The least-squares affine fit mapping each correspondence's `source`
    /// onto its `target`, or `nil` if there are fewer than three
    /// correspondences or their source points are (nearly) collinear, which
    /// leaves the transform underdetermined.
    ///
    /// Coordinates are centered on their centroids before solving, which
    /// keeps the normal equations well-conditioned for points thousands of
    /// pixels from the origin and separates the problem into a 2x2 solve for
    /// the linear part plus a translation recovered from the centroids.
    /// With exactly three non-collinear points this is an exact fit, which
    /// is what RANSAC's minimal samples use.
    public static func leastSquares(_ correspondences: [PointCorrespondence]) -> AffineTransform2D? {
        let n = Double(correspondences.count)
        guard correspondences.count >= 3 else { return nil }

        var meanSource = Point2D(x: 0, y: 0)
        var meanTarget = Point2D(x: 0, y: 0)
        for pair in correspondences {
            meanSource.x += pair.source.x
            meanSource.y += pair.source.y
            meanTarget.x += pair.target.x
            meanTarget.y += pair.target.y
        }
        meanSource.x /= n
        meanSource.y /= n
        meanTarget.x /= n
        meanTarget.y /= n

        var sxx = 0.0, sxy = 0.0, syy = 0.0
        var sxu = 0.0, syu = 0.0, sxv = 0.0, syv = 0.0
        for pair in correspondences {
            let x = pair.source.x - meanSource.x
            let y = pair.source.y - meanSource.y
            let u = pair.target.x - meanTarget.x
            let v = pair.target.y - meanTarget.y
            sxx += x * x
            sxy += x * y
            syy += y * y
            sxu += x * u
            syu += y * u
            sxv += x * v
            syv += y * v
        }

        let det = sxx * syy - sxy * sxy
        // Relative to the spread itself, so the collinearity check means
        // the same thing for a 10px triangle and a 1000px one.
        guard det > 1e-9 * max(1e-12, sxx * syy), det.isFinite else { return nil }

        let a = (sxu * syy - syu * sxy) / det
        let b = (syu * sxx - sxu * sxy) / det
        let c = (sxv * syy - syv * sxy) / det
        let d = (syv * sxx - sxv * sxy) / det
        let tx = meanTarget.x - a * meanSource.x - b * meanSource.y
        let ty = meanTarget.y - c * meanSource.x - d * meanSource.y
        return AffineTransform2D(a: a, b: b, tx: tx, c: c, d: d, ty: ty)
    }
}
