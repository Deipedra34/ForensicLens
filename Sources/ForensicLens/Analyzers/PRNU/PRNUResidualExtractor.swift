/// Extracts an image's sensor-noise residual `W = I - F(I)`: the luminance
/// minus a denoised copy of itself. What's left is mostly noise, and the
/// part of that noise that repeats across every photo from one sensor is
/// its PRNU (photo response non-uniformity) pattern.
///
/// `F` is the wavelet-domain, locally adaptive Wiener denoiser of Mihcak,
/// Kozintsev & Ramchandran (1999), in the configuration Lukas, Fridrich &
/// Goljan (2006) introduced for PRNU extraction:
///
/// 1. A 4-level db4 wavelet decomposition (`DaubechiesWavelet`).
/// 2. In every detail subband, each coefficient `w`'s local signal variance
///    is estimated as `max(0, mean(w^2) - sigma0^2)` over a square window,
///    taking the smallest estimate across 3x3, 5x5, 7x7 and 9x9 windows,
///    where `sigma0` is the assumed noise level (`noiseSigma`).
/// 3. The Wiener filter keeps `w * s2 / (s2 + sigma0^2)` of each coefficient.
///    The residual is the remainder, `w * sigma0^2 / (s2 + sigma0^2)`. That
///    is nearly all of `w` in flat areas, where the coefficient is mostly
///    noise, and very little of it on edges and texture, where it's mostly
///    content.
/// 4. The approximation subband counts as pure content (residual zero), and
///    the residual coefficients are inverted back to pixels. Since the
///    transform is orthonormal and linear, that equals `I - F(I)` exactly,
///    without reconstructing `F(I)` first.
/// 5. Zero-meaning: every column's mean, then every row's mean, is
///    subtracted. This removes the "linear pattern" of row and column
///    artifacts that readout electronics leave behind. That pattern is
///    shared by every sensor of a model rather than unique to one, so it
///    would otherwise inflate correlations between different cameras.
///
/// Fridrich's full pipeline also Wiener-filters the residual's Fourier
/// spectrum to flatten periodic artifacts (JPEG's 8x8 grid in particular).
/// That's left out: this package only decodes uncompressed BMP/PPM pixels,
/// and the step matters mainly for fingerprints built from JPEGs.
enum PRNUResidualExtractor {
    /// Decomposition depth. Four levels is the standard choice: it pushes
    /// the approximation subband (treated as pure content) down to 1/16
    /// scale, so the residual keeps almost the whole noise spectrum.
    static let waveletLevels = 4

    /// Assumed noise standard deviation `sigma0`, in 8-bit gray levels.
    /// 3 is the value commonly used for 8-bit camera images. Lower values
    /// keep less noise in the residual; higher values let more scene
    /// content leak into it.
    static let noiseSigma = 3.0

    /// Window sizes for the local variance estimate, from Mihcak et al.
    static let varianceWindowSizes = [3, 5, 7, 9]

    /// The zero-meaned noise residual of `luma`, the same size as `luma`.
    /// An empty plane gives an empty residual.
    static func residual(of luma: PRNUPlane) -> PRNUPlane {
        guard luma.width > 0, luma.height > 0 else { return luma }

        let multiple = 1 << waveletLevels
        let paddedWidth = (luma.width + multiple - 1) / multiple * multiple
        let paddedHeight = (luma.height + multiple - 1) / multiple * multiple

        var coefficients = luma.mirrorPadded(toWidth: paddedWidth, height: paddedHeight)
        DaubechiesWavelet.forward(&coefficients, levels: waveletLevels)

        // Starts all zero, so the approximation subband stays zero.
        var residualCoefficients = PRNUPlane(width: paddedWidth, height: paddedHeight)
        let noiseVariance = noiseSigma * noiseSigma
        for level in 1...waveletLevels {
            for band in DaubechiesWavelet.detailSubbands(width: paddedWidth, height: paddedHeight, level: level) {
                let bandValues = extract(band, from: coefficients)
                let residualBand = wienerResidual(bandValues, width: band.width, height: band.height, noiseVariance: noiseVariance)
                store(residualBand, in: band, of: &residualCoefficients)
            }
        }

        DaubechiesWavelet.inverse(&residualCoefficients, levels: waveletLevels)
        let cropped = residualCoefficients.cropped(to: Region(x: 0, y: 0, width: luma.width, height: luma.height))
        return zeroMeaned(cropped)
    }

    /// The Wiener residual of one subband's coefficients (see step 3 in
    /// this type's doc comment). Not `private`, so the shrinkage rule can
    /// be unit-tested on its own.
    static func wienerResidual(_ coefficients: [Double], width: Int, height: Int, noiseVariance: Double) -> [Double] {
        guard width > 0, height > 0, coefficients.count == width * height, noiseVariance > 0 else {
            return coefficients
        }
        let squared = coefficients.map { $0 * $0 }
        var signalVariance = [Double](repeating: .infinity, count: coefficients.count)
        for window in varianceWindowSizes {
            let means = localMeans(of: squared, width: width, height: height, window: window)
            for i in 0..<signalVariance.count {
                signalVariance[i] = min(signalVariance[i], max(0, means[i] - noiseVariance))
            }
        }
        var residual = [Double](repeating: 0, count: coefficients.count)
        for i in 0..<residual.count {
            residual[i] = coefficients[i] * noiseVariance / (signalVariance[i] + noiseVariance)
        }
        return residual
    }

    /// Mean of `values` over a `window` x `window` square centered on each
    /// sample, clipped at the edges (averaging only the samples that exist).
    /// Uses a summed-area table, so the cost doesn't depend on `window`.
    static func localMeans(of values: [Double], width: Int, height: Int, window: Int) -> [Double] {
        guard width > 0, height > 0, values.count == width * height else { return values }
        let radius = max(0, window / 2)
        let stride = width + 1
        var integral = [Double](repeating: 0, count: stride * (height + 1))
        for y in 0..<height {
            var rowSum = 0.0
            for x in 0..<width {
                rowSum += values[y * width + x]
                integral[(y + 1) * stride + x + 1] = integral[y * stride + x + 1] + rowSum
            }
        }

        var means = [Double](repeating: 0, count: values.count)
        for y in 0..<height {
            let y0 = max(0, y - radius)
            let y1 = min(height, y + radius + 1)
            for x in 0..<width {
                let x0 = max(0, x - radius)
                let x1 = min(width, x + radius + 1)
                let sum = integral[y1 * stride + x1] - integral[y0 * stride + x1] - integral[y1 * stride + x0] + integral[y0 * stride + x0]
                means[y * width + x] = sum / Double((y1 - y0) * (x1 - x0))
            }
        }
        return means
    }

    /// Subtracts every column's mean, then every row's mean (step 5 in
    /// this type's doc comment).
    static func zeroMeaned(_ plane: PRNUPlane) -> PRNUPlane {
        guard plane.width > 0, plane.height > 0 else { return plane }
        var result = plane
        let width = plane.width
        let height = plane.height

        for x in 0..<width {
            var sum = 0.0
            for y in 0..<height { sum += result.values[y * width + x] }
            let mean = sum / Double(height)
            for y in 0..<height { result.values[y * width + x] -= mean }
        }
        for y in 0..<height {
            let rowStart = y * width
            var sum = 0.0
            for x in 0..<width { sum += result.values[rowStart + x] }
            let mean = sum / Double(width)
            for x in 0..<width { result.values[rowStart + x] -= mean }
        }
        return result
    }

    private static func extract(_ band: DaubechiesWavelet.Subband, from plane: PRNUPlane) -> [Double] {
        var values = [Double](repeating: 0, count: band.width * band.height)
        for y in 0..<band.height {
            let source = (band.y + y) * plane.width + band.x
            for x in 0..<band.width {
                values[y * band.width + x] = plane.values[source + x]
            }
        }
        return values
    }

    private static func store(_ values: [Double], in band: DaubechiesWavelet.Subband, of plane: inout PRNUPlane) {
        for y in 0..<band.height {
            let destination = (band.y + y) * plane.width + band.x
            for x in 0..<band.width {
                plane.values[destination + x] = values[y * band.width + x]
            }
        }
    }
}
