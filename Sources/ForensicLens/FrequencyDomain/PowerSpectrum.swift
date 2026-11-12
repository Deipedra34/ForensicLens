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

    /// The power spectrum of a `size` x `size` row-major real plane.
    ///
    /// The plane's mean is subtracted first, so the zero-frequency bin
    /// holds only what windowing leaves there rather than the overall
    /// brightness dwarfing every other bin. With `windowed` (the default)
    /// the plane is then multiplied by a separable 2D Hann window (see
    /// `hannWindow(size:)`) before the forward transform. Power is
    /// `re^2 + im^2`, unnormalized; analyses compare bins against each
    /// other, so the absolute scale doesn't matter.
    ///
    /// `nil` unless `size` is a power of two of at least 2 and `plane`
    /// holds exactly `size * size` samples.
    init?(of plane: [Double], size: Int, windowed: Bool = true) {
        guard size >= 2, FFT.isPowerOfTwo(size), plane.count == size * size else { return nil }

        let mean = plane.reduce(0, +) / Double(plane.count)
        var real = plane.map { $0 - mean }
        if windowed {
            let window = Self.hannWindow(size: size)
            for y in 0..<size {
                let rowWeight = window[y]
                for x in 0..<size {
                    real[y * size + x] *= rowWeight * window[x]
                }
            }
        }
        var imaginary = [Double](repeating: 0, count: plane.count)
        guard FFT.transform2D(&real, &imaginary, width: size, height: size, inverse: false) else { return nil }

        var power = [Double](repeating: 0, count: plane.count)
        for i in 0..<power.count {
            power[i] = real[i] * real[i] + imaginary[i] * imaginary[i]
        }
        self.init(size: size, values: power)
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

    // MARK: - Local statistics

    /// The largest power within Chebyshev distance `radius` of `(u, v)`
    /// (a `(2 * radius + 1)`-square), wrapping around the edges.
    ///
    /// A windowed tone that falls between two bins, or the Hann window's
    /// own one-bin spread, can move a peak's maximum off its nominal bin;
    /// taking the local maximum over radius 1 catches it either way.
    func localPeak(u: Int, v: Int, radius: Int = 1) -> Double {
        let r = max(0, radius)
        var peak = 0.0
        for dv in -r...r {
            for du in -r...r {
                peak = max(peak, self[u + du, v + dv])
            }
        }
        return peak
    }

    /// The median power over the square ring of bins whose Chebyshev
    /// distance from `(u, v)` lies in `innerRadius...outerRadius`, wrapping
    /// around the edges. `nil` if the ring is empty (an inner radius above
    /// the outer one) or would cover the whole spectrum more than once.
    ///
    /// This is the local "what the spectrum looks like around here"
    /// baseline a candidate peak is compared against. The ring skips the
    /// bins the peak itself spreads into, and a median rather than a mean
    /// keeps one unrelated strong bin in the ring from inflating the
    /// baseline and hiding a real peak.
    func ringMedian(u: Int, v: Int, innerRadius: Int, outerRadius: Int) -> Double? {
        let inner = max(0, innerRadius)
        guard outerRadius >= inner, 2 * outerRadius + 1 <= size else { return nil }
        var ring: [Double] = []
        ring.reserveCapacity((2 * outerRadius + 1) * (2 * outerRadius + 1))
        for dv in -outerRadius...outerRadius {
            for du in -outerRadius...outerRadius where max(abs(du), abs(dv)) >= inner {
                ring.append(self[u + du, v + dv])
            }
        }
        guard !ring.isEmpty else { return nil }
        ring.sort()
        let middle = ring.count / 2
        return ring.count % 2 == 1 ? ring[middle] : 0.5 * (ring[middle - 1] + ring[middle])
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
