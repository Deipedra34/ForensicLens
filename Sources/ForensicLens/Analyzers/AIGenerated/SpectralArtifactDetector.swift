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
