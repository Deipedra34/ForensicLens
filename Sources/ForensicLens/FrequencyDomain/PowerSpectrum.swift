import Foundation

/// The 2D power spectrum of a square, real-valued plane: `|F(u, v)|^2` at
/// every frequency bin, built on `FFT`.
///
/// Spectral analysis asks a different question than PRNU's correlation
/// planes: not "where does this pattern line up", but "is there energy
/// concentrated at one particular spatial frequency". A periodic pattern
/// that repeats every `p` pixels puts sharp peaks at bins that are
/// multiples of `size / p`, while noise and natural image content spread
/// their energy smoothly across neighboring bins. This type holds the
/// spectrum and answers the local questions such an analysis needs.
///
/// Bins are stored row-major with the zero frequency at `(0, 0)` (no
/// quadrant shift). Indices wrap around, so `(-1, 0)` and `(size - 1, 0)`
/// name the same bin, which matches the periodicity of the discrete
/// Fourier transform itself and lets neighborhood queries cross the edges
/// without special cases.
struct PowerSpectrum: Sendable, Equatable {
    /// Side length in bins. Always a power of two of at least 2.
    let size: Int

    /// `size * size` power values, row-major, `v * size + u`.
    let values: [Double]

    /// Wraps precomputed `values`. `nil` unless `size` is a power of two of
    /// at least 2 and `values` holds exactly `size * size` samples.
    init?(size: Int, values: [Double]) {
        guard size >= 2, FFT.isPowerOfTwo(size), values.count == size * size else { return nil }
        self.size = size
        self.values = values
    }

    /// The power at horizontal frequency bin `u` and vertical bin `v`,
    /// wrapping both around the spectrum's edges.
    subscript(u: Int, v: Int) -> Double {
        values[wrap(v) * size + wrap(u)]
    }

    /// `index` reduced into `0..<size`, including for negative values.
    func wrap(_ index: Int) -> Int {
        let remainder = index % size
        return remainder < 0 ? remainder + size : remainder
    }

    /// Mean power over every bin except the zero frequency, or 0 for an
    /// all-zero spectrum.
    var meanNonZeroFrequencyPower: Double {
        guard values.count > 1 else { return 0 }
        return (values.reduce(0, +) - values[0]) / Double(values.count - 1)
    }

    // MARK: - Windowing

    /// The 1D periodic Hann window of length `size`:
    /// `w(n) = 0.5 - 0.5 * cos(2 * pi * n / size)`.
    ///
    /// Transforming a finite crop treats it as one period of an infinite
    /// tiling, so any mismatch between its left and right (or top and
    /// bottom) edges becomes a sharp step that smears energy along both
    /// frequency axes. Tapering the crop to zero at its borders removes
    /// that step. The periodic form (dividing by `size`, not `size - 1`)
    /// spreads a pure on-bin tone over exactly three bins with weights
    /// `1/4, 1/2, 1/4`, so a peak's energy never leaks further than one bin
    /// either side.
    static func hannWindow(size: Int) -> [Double] {
        guard size > 0 else { return [] }
        return (0..<size).map { 0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(size)) }
    }
}
