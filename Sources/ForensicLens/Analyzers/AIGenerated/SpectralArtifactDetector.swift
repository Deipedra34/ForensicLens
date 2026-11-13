import Foundation

/// Looks for the periodic, grid-like spectral peaks that generative-model
/// upsampling layers tend to leave in an image's fine detail.
///
/// GAN and many diffusion decoders build an image up from a small latent
/// through repeated 2x upsampling: transposed convolutions, or nearest /
/// pixel-shuffle upsampling followed by convolutions. Each of those layers
/// treats output pixels differently depending on their position modulo
/// the upsampling factor, which leaves a faint pattern that repeats every
/// 2, 4 or 8 pixels (the well-known "checkerboard artifact"). In the
/// Fourier spectrum of the image's high-frequency residual, a pattern with
/// period `p` shows up as sharp peaks at bins that are multiples of
/// `size / p` on both axes, standing well above the smooth spectrum that
/// camera noise and natural texture produce. This type measures exactly
/// that and nothing else; turning the measurement into a finding, and
/// combining it with other evidence, happens elsewhere.
enum SpectralArtifactDetector {
    /// The upsampling periods, in pixels, whose spectral lattices are
    /// checked: one, two and three stacked 2x upsampling stages. A period-8
    /// lattice contains the period-4 and period-2 ones, so in practice the
    /// candidate set is every multiple of `size / 8`.
    static let upsamplingPeriods = [2, 4, 8]

    /// Smallest analysis crop, in pixels. Below this the lattice bins sit
    /// too close together (8 bins apart for period 8) for a ring of
    /// background bins to fit between them, and too few samples feed each
    /// bin for a stable estimate.
    static let minimumCropSize = 64

    /// Largest analysis crop, in pixels. 512x512 gives each lattice bin
    /// plenty of averaging while bounding the transform at about a quarter
    /// of a million samples, whatever the image size.
    static let maximumCropSize = 512

    // MARK: - Analysis crop

    /// The side length of the square, power-of-two crop analyzed for a
    /// `width` x `height` image: the largest power of two that fits both
    /// dimensions, capped at `maximumCropSize`. `nil` if even
    /// `minimumCropSize` doesn't fit.
    ///
    /// The crop is taken at native resolution and never resampled, since
    /// resampling would itself imprint a new periodic structure and wipe
    /// out the one being measured.
    static func cropSize(width: Int, height: Int) -> Int? {
        let fit = min(width, height)
        guard fit >= minimumCropSize else { return nil }
        var size = minimumCropSize
        while size * 2 <= fit && size * 2 <= maximumCropSize { size *= 2 }
        return size
    }

    /// The centered `cropSize` square of `luma`, as a region in its pixel
    /// coordinates. `nil` if the image is too small.
    static func cropRegion(width: Int, height: Int) -> Region? {
        guard let size = cropSize(width: width, height: height) else { return nil }
        return Region(x: (width - size) / 2, y: (height - size) / 2, width: size, height: size)
    }

    /// The high-frequency residual of `plane`: each sample minus the mean
    /// of the 3x3 neighborhood around it.
    ///
    /// Natural images put almost all their energy at low frequencies, and
    /// that slope would otherwise dominate the spectrum and bury faint
    /// high-frequency peaks under the window's sidelobes. Upsampling
    /// artifacts live in the fine detail, mostly at periods of 2 to 8
    /// pixels, which a 3x3 high-pass keeps. It reuses the summed-area local
    /// mean from PRNU residual extraction rather than the full wavelet
    /// denoiser, which would cost far more and is tuned to keep noise, not
    /// periodic structure.
    static func highPassResidual(_ plane: PRNUPlane) -> PRNUPlane {
        guard plane.width > 0, plane.height > 0 else { return plane }
        let means = PRNUResidualExtractor.localMeans(of: plane.values, width: plane.width, height: plane.height, window: 3)
        var residual = plane.values
        for i in 0..<residual.count {
            residual[i] -= means[i]
        }
        return PRNUPlane(width: plane.width, height: plane.height, values: residual)
    }

    // MARK: - Measurement

    /// Inner and outer Chebyshev radius of the ring of bins each candidate
    /// is compared against. The inner radius skips the one-bin spread a
    /// windowed peak leaks into its neighbors; the outer one stays short of
    /// the next lattice bin even at the minimum crop size.
    static let backgroundInnerRadius = 2
    static let backgroundOuterRadius = 4

    /// Upper bound on a reported peak-to-background ratio. A perfectly
    /// periodic synthetic pattern on a noise-free background has a
    /// background of essentially zero; capping keeps the ratio finite and
    /// printable without changing any decision made from it.
    static let maximumPeakRatio = 1e6

    /// Mean residual energy per sample (in squared gray levels) below
    /// which the crop counts as having no fine detail at all: a flat or
    /// nearly flat image, whose spectrum is floating-point dust.
    static let minimumResidualEnergy = 1e-4

    /// Measures every lattice frequency of `luma`'s centered analysis crop.
    static func measure(_ luma: PRNUPlane) -> SpectralArtifactMeasurement {
        guard let region = cropRegion(width: luma.width, height: luma.height) else {
            return .insufficientData("the image is smaller than the \(minimumCropSize)x\(minimumCropSize) px a spectral check needs")
        }
        let residual = highPassResidual(luma.cropped(to: region))
        let size = region.width
        let energy = residual.values.reduce(0) { $0 + $1 * $1 } / Double(max(1, residual.values.count))
        guard energy >= minimumResidualEnergy else {
            return .insufficientData("the analyzed area has no fine detail (a flat or nearly flat image)")
        }
        guard let spectrum = PowerSpectrum(of: residual.values, size: size) else {
            return .insufficientData("the analyzed area could not be transformed")
        }

        let floor = max(spectrum.meanNonZeroFrequencyPower * 1e-9, Double.leastNormalMagnitude)
        let peaks = latticeFrequencies(size: size).map { bin -> SpectralArtifactMeasurement.LatticePeak in
            let peak = spectrum.localPeak(u: bin.u, v: bin.v)
            let background = spectrum.ringMedian(u: bin.u, v: bin.v, innerRadius: backgroundInnerRadius, outerRadius: backgroundOuterRadius) ?? 0
            let ratio = min(maximumPeakRatio, peak / max(background, floor))
            return SpectralArtifactMeasurement.LatticePeak(bin: bin, period: period(of: bin, size: size), ratio: ratio)
        }
        return SpectralArtifactMeasurement(status: .measured, analyzedRegion: region, cropSize: size, peaks: peaks)
    }

    /// The shortest of `upsamplingPeriods` whose lattice contains `bin`
    /// (0 if none does).
    static func period(of bin: Bin, size: Int) -> Int {
        for period in upsamplingPeriods.sorted() where (bin.u * period) % size == 0 && (bin.v * period) % size == 0 {
            return period
        }
        return 0
    }

    // MARK: - Lattice frequencies

    /// The frequency bin `(u, v)` of a candidate lattice peak.
    struct Bin: Hashable, Sendable {
        let u: Int
        let v: Int
    }

    /// Every non-zero frequency on the lattices of `periods` in a
    /// `size` x `size` spectrum, one bin per conjugate pair.
    ///
    /// A real image's spectrum is conjugate-symmetric (`P(u, v)` equals
    /// `P(-u, -v)`), so each pair is listed once, as whichever of the two
    /// comes first in row-major order. Periods that don't divide `size`
    /// contribute nothing. Sorted row-major, so the output is
    /// deterministic.
    static func latticeFrequencies(size: Int, periods: [Int] = upsamplingPeriods) -> [Bin] {
        guard size > 0 else { return [] }
        var bins = Set<Bin>()
        for period in periods where period > 1 && size % period == 0 {
            let step = size / period
            for j in 0..<period {
                for i in 0..<period where i != 0 || j != 0 {
                    bins.insert(canonical(Bin(u: i * step, v: j * step), size: size))
                }
            }
        }
        return bins.sorted { ($0.v, $0.u) < ($1.v, $1.u) }
    }

    /// `bin` or its conjugate `(-u, -v)`, whichever comes first in
    /// row-major order.
    static func canonical(_ bin: Bin, size: Int) -> Bin {
        let mirror = Bin(u: (size - bin.u) % size, v: (size - bin.v) % size)
        return (mirror.v, mirror.u) < (bin.v, bin.u) ? mirror : bin
    }
}
