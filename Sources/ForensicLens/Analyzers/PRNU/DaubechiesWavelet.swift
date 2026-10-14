/// A multi-level, orthonormal 2D discrete wavelet transform using the
/// 8-tap Daubechies filter (db4, four vanishing moments) with periodic
/// boundary handling, laid out in the usual in-place (Mallat) arrangement.
///
/// This is the transform the standard PRNU noise extractor (Lukas,
/// Fridrich & Goljan, 2006) denoises in. It's implemented directly rather
/// than through a signal-processing library because the only one that ships
/// with an OS (Accelerate's vDSP) is Apple-only, and an 8-tap filter bank is
/// short enough to write and verify by hand. Orthonormality is what makes
/// it convenient here: the inverse is exactly the transpose of the forward
/// transform, so `inverse(forward(x)) == x` up to rounding error (covered by
/// a unit test), and the transform is linear, so a residual can be
/// assembled in the wavelet domain and inverted on its own.
///
/// After `forward(_:levels:)` on a `W` x `H` plane, level `l` (1-based) has
/// three detail subbands of size `(W >> l)` x `(H >> l)` (see
/// `detailSubbands`), and the top-left `(W >> levels)` x `(H >> levels)`
/// corner holds the final approximation. Both dimensions must be divisible
/// by `2^levels`; `PRNUResidualExtractor` mirror-pads its input to make
/// sure they are.
enum DaubechiesWavelet {
    /// Daubechies db4 analysis low-pass filter. Its coefficients sum to
    /// sqrt(2) and are orthonormal to their own even shifts.
    static let lowPass: [Double] = [
        0.2303778133088964, 0.7148465705529154, 0.6308807679298587, -0.0279837694168599,
        -0.1870348117190931, 0.0308413818355607, 0.0328830116668852, -0.0105974017850690,
    ]

    /// The matching high-pass (quadrature mirror) filter:
    /// `g[k] = (-1)^k * h[N-1-k]`.
    static let highPass: [Double] = {
        let taps = DaubechiesWavelet.lowPass
        return (0..<taps.count).map { k in (k % 2 == 0 ? 1.0 : -1.0) * taps[taps.count - 1 - k] }
    }()

    /// One detail subband's rectangle within the transformed plane.
    struct Subband: Equatable {
        let x: Int
        let y: Int
        let width: Int
        let height: Int
    }

    /// Whether a `width` x `height` plane can be transformed to `levels`
    /// levels: both sides must be positive multiples of `2^levels`.
    static func canTransform(width: Int, height: Int, levels: Int) -> Bool {
        guard levels >= 0, width > 0, height > 0 else { return false }
        let multiple = 1 << levels
        return width % multiple == 0 && height % multiple == 0
    }

    /// The three detail subbands produced at `level` (1-based) of a
    /// `width` x `height` transform: high-pass horizontally (top-right),
    /// vertically (bottom-left), and in both directions (bottom-right).
    static func detailSubbands(width: Int, height: Int, level: Int) -> [Subband] {
        let bandWidth = width >> level
        let bandHeight = height >> level
        return [
            Subband(x: bandWidth, y: 0, width: bandWidth, height: bandHeight),
            Subband(x: 0, y: bandHeight, width: bandWidth, height: bandHeight),
            Subband(x: bandWidth, y: bandHeight, width: bandWidth, height: bandHeight),
        ]
    }

    /// Transforms `plane` in place. Does nothing if its size isn't
    /// divisible by `2^levels` (see `canTransform`).
    static func forward(_ plane: inout PRNUPlane, levels: Int) {
        guard canTransform(width: plane.width, height: plane.height, levels: levels) else { return }
        let width = plane.width
        var line = [Double](repeating: 0, count: max(plane.width, plane.height))
        var output = line

        for level in 0..<levels {
            let currentWidth = width >> level
            let currentHeight = plane.height >> level

            for y in 0..<currentHeight {
                let rowStart = y * width
                for x in 0..<currentWidth { line[x] = plane.values[rowStart + x] }
                analyze(line, count: currentWidth, into: &output)
                for x in 0..<currentWidth { plane.values[rowStart + x] = output[x] }
            }
            for x in 0..<currentWidth {
                for y in 0..<currentHeight { line[y] = plane.values[y * width + x] }
                analyze(line, count: currentHeight, into: &output)
                for y in 0..<currentHeight { plane.values[y * width + x] = output[y] }
            }
        }
    }

    /// Inverts `forward(_:levels:)` in place, undoing the levels coarsest
    /// first and, within each level, columns before rows. Does nothing if
    /// the plane's size isn't divisible by `2^levels`.
    static func inverse(_ plane: inout PRNUPlane, levels: Int) {
        guard canTransform(width: plane.width, height: plane.height, levels: levels) else { return }
        let width = plane.width
        var line = [Double](repeating: 0, count: max(plane.width, plane.height))
        var output = line

        for level in (0..<levels).reversed() {
            let currentWidth = width >> level
            let currentHeight = plane.height >> level

            for x in 0..<currentWidth {
                for y in 0..<currentHeight { line[y] = plane.values[y * width + x] }
                synthesize(line, count: currentHeight, into: &output)
                for y in 0..<currentHeight { plane.values[y * width + x] = output[y] }
            }
            for y in 0..<currentHeight {
                let rowStart = y * width
                for x in 0..<currentWidth { line[x] = plane.values[rowStart + x] }
                synthesize(line, count: currentWidth, into: &output)
                for x in 0..<currentWidth { plane.values[rowStart + x] = output[x] }
            }
        }
    }

    /// One periodized analysis step over `input[0..<count]` (`count` even):
    /// approximation coefficients into `output[0..<count/2]`, details into
    /// `output[count/2..<count]`.
    private static func analyze(_ input: [Double], count: Int, into output: inout [Double]) {
        let half = count / 2
        let taps = lowPass.count
        for i in 0..<half {
            var approximation = 0.0
            var detail = 0.0
            for k in 0..<taps {
                let value = input[(2 * i + k) % count]
                approximation += lowPass[k] * value
                detail += highPass[k] * value
            }
            output[i] = approximation
            output[half + i] = detail
        }
    }

    /// The transpose of `analyze`, which for an orthonormal filter bank is
    /// its exact inverse.
    private static func synthesize(_ input: [Double], count: Int, into output: inout [Double]) {
        let half = count / 2
        let taps = lowPass.count
        for i in 0..<count { output[i] = 0 }
        for i in 0..<half {
            let approximation = input[i]
            let detail = input[half + i]
            for k in 0..<taps {
                output[(2 * i + k) % count] += lowPass[k] * approximation + highPass[k] * detail
            }
        }
    }
}
