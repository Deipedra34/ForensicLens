/// A cheap high-pass residual for noise-level estimation: each pixel's
/// response to Immerkaer's 3x3 second-difference mask
///
///     1  -2   1
///    -2   4  -2
///     1  -2   1
///
/// (J. Immerkaer, "Fast Noise Variance Estimation", Computer Vision and
/// Image Understanding 64(2), 1996). The mask is the difference of two
/// Laplacians, so it cancels any constant level and any linear gradient
/// in either direction. What's left in smooth areas is almost entirely
/// noise; edges and fine texture still leak through, which is why
/// `NoiseVariance` prefers a median-based estimate.
///
/// **Why not reuse `PRNUResidualExtractor`?** That residual is built for a
/// different job: isolating the faint, fixed sensor pattern PRNU
/// correlates against. It runs a 4-level wavelet transform with an 8-tap
/// filter, a four-window local variance estimate in every detail subband,
/// and an inverse transform -- a few hundred floating-point operations per
/// pixel, on a padded whole-image plane. Measuring *how much* noise a block
/// has needs none of that precision. This mask costs nine multiply-adds per
/// pixel, works on one block at a time, and needs no padding beyond a
/// one-pixel border, which is what makes the noise-level check cheap enough
/// to run first, or always.
enum NoiseResidual {
    /// The mask's coefficients, row-major.
    static let mask: [Double] = [
        1, -2, 1,
        -2, 4, -2,
        1, -2, 1,
    ]

    /// Square root of the sum of the squared coefficients. For independent
    /// noise of standard deviation `sigma`, the mask's response has standard
    /// deviation `maskNorm * sigma`, so dividing by it puts residual
    /// statistics back on the scale of the noise itself.
    static let maskNorm = 6.0

    /// The mask's response at every pixel of `plane` that has all eight
    /// neighbors: a `(width - 2)` x `(height - 2)` plane. A plane smaller
    /// than 3x3 has no such pixel and gives an empty plane.
    static func highPass(_ plane: PRNUPlane) -> PRNUPlane {
        let width = plane.width
        let height = plane.height
        guard width >= 3, height >= 3 else { return PRNUPlane(width: 0, height: 0) }

        let outWidth = width - 2
        let outHeight = height - 2
        let v = plane.values
        var out = [Double](repeating: 0, count: outWidth * outHeight)
        for y in 0..<outHeight {
            let top = y * width
            let middle = top + width
            let bottom = middle + width
            for x in 0..<outWidth {
                let corners = v[top + x] + v[top + x + 2] + v[bottom + x] + v[bottom + x + 2]
                let edges = v[top + x + 1] + v[middle + x] + v[middle + x + 2] + v[bottom + x + 1]
                out[y * outWidth + x] = corners - 2 * edges + 4 * v[middle + x + 1]
            }
        }
        return PRNUPlane(width: outWidth, height: outHeight, values: out)
    }
}
