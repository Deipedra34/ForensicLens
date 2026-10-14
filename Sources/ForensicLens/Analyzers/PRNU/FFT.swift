import Foundation

/// A plain-Swift, radix-2 fast Fourier transform, in 1D and 2D.
///
/// PRNU camera verification needs a correlation plane: the normalized
/// cross-correlation between two images at every relative shift. That's
/// what PCE (peak-to-correlation energy) measures its peak against.
/// Computed directly, every shift costs a full pass over the image, which
/// is quadratic in pixel count and impractical beyond thumbnails. The FFT
/// computes the whole plane in `O(N log N)`.
///
/// Accelerate's vDSP FFT is the usual choice on Apple platforms, but it
/// doesn't exist on Linux, and this package builds and tests the same way
/// on both. Wrapping FFTW or another C library would add a system
/// dependency to a package that has none. So this is a textbook iterative
/// Cooley-Tukey transform (bit-reversal permutation, then in-place
/// butterflies with precomputed twiddles), small enough to check by eye and
/// covered by its own unit tests. Sizes must be powers of two; callers
/// zero-pad up to `nextPowerOfTwo`. A plain-Swift radix-2 transform is
/// several times slower than vDSP, but it only runs once per analyzed image
/// in reference mode, so it doesn't decide the analyzer's overall cost.
enum FFT {
    static func isPowerOfTwo(_ n: Int) -> Bool {
        n > 0 && (n & (n - 1)) == 0
    }

    /// The smallest power of two `>= n` (1 for `n <= 1`).
    static func nextPowerOfTwo(_ n: Int) -> Int {
        var size = 1
        while size < n { size <<= 1 }
        return size
    }

    /// Precomputed bit-reversal order and twiddle factors for one size.
    struct Plan {
        let size: Int
        let bitReversed: [Int]
        let cosines: [Double]
        let sines: [Double]

        /// `nil` unless `size` is a power of two.
        init?(size: Int) {
            guard FFT.isPowerOfTwo(size) else { return nil }
            self.size = size

            var bits = 0
            while (1 << bits) < size { bits += 1 }
            var reversed = [Int](repeating: 0, count: size)
            for i in 0..<size {
                var value = i
                var result = 0
                for _ in 0..<bits {
                    result = (result << 1) | (value & 1)
                    value >>= 1
                }
                reversed[i] = result
            }
            bitReversed = reversed

            let half = max(1, size / 2)
            cosines = (0..<half).map { cos(2 * Double.pi * Double($0) / Double(size)) }
            sines = (0..<half).map { sin(2 * Double.pi * Double($0) / Double(size)) }
        }
    }

    /// In-place complex transform of `real`/`imaginary` (both `plan.size`
    /// long). The forward transform uses the `e^(-2*pi*i*k*n/N)` kernel; the
    /// inverse uses `e^(+2*pi*i*k*n/N)` and divides by `N`, so a forward
    /// transform followed by an inverse returns the input.
    static func transform(_ real: inout [Double], _ imaginary: inout [Double], plan: Plan, inverse: Bool) {
        let n = plan.size
        guard real.count == n, imaginary.count == n, n > 1 else { return }

        for i in 0..<n {
            let j = plan.bitReversed[i]
            if j > i {
                real.swapAt(i, j)
                imaginary.swapAt(i, j)
            }
        }

        var length = 2
        while length <= n {
            let half = length / 2
            let twiddleStep = n / length
            var start = 0
            while start < n {
                for k in 0..<half {
                    let t = k * twiddleStep
                    let wr = plan.cosines[t]
                    let wi = inverse ? plan.sines[t] : -plan.sines[t]
                    let a = start + k
                    let b = a + half
                    let xr = real[b] * wr - imaginary[b] * wi
                    let xi = real[b] * wi + imaginary[b] * wr
                    real[b] = real[a] - xr
                    imaginary[b] = imaginary[a] - xi
                    real[a] += xr
                    imaginary[a] += xi
                }
                start += length
            }
            length <<= 1
        }

        if inverse {
            let scale = 1 / Double(n)
            for i in 0..<n {
                real[i] *= scale
                imaginary[i] *= scale
            }
        }
    }

    /// In-place 2D transform of a row-major `width` x `height` complex
    /// plane: every row, then every column. Returns `false` (leaving the
    /// input untouched) unless both sizes are powers of two and the arrays
    /// match them.
    @discardableResult
    static func transform2D(_ real: inout [Double], _ imaginary: inout [Double], width: Int, height: Int, inverse: Bool) -> Bool {
        guard let rowPlan = Plan(size: width), let columnPlan = Plan(size: height),
              real.count == width * height, imaginary.count == width * height
        else { return false }

        var lineReal = [Double](repeating: 0, count: width)
        var lineImaginary = [Double](repeating: 0, count: width)
        for y in 0..<height {
            let rowStart = y * width
            for x in 0..<width {
                lineReal[x] = real[rowStart + x]
                lineImaginary[x] = imaginary[rowStart + x]
            }
            transform(&lineReal, &lineImaginary, plan: rowPlan, inverse: inverse)
            for x in 0..<width {
                real[rowStart + x] = lineReal[x]
                imaginary[rowStart + x] = lineImaginary[x]
            }
        }

        var columnReal = [Double](repeating: 0, count: height)
        var columnImaginary = [Double](repeating: 0, count: height)
        for x in 0..<width {
            for y in 0..<height {
                columnReal[y] = real[y * width + x]
                columnImaginary[y] = imaginary[y * width + x]
            }
            transform(&columnReal, &columnImaginary, plan: columnPlan, inverse: inverse)
            for y in 0..<height {
                real[y * width + x] = columnReal[y]
                imaginary[y * width + x] = columnImaginary[y]
            }
        }
        return true
    }

    /// The circular cross-correlation of two real `width` x `height`
    /// planes (both powers of two): `c[s] = sum over p of a[p + s] * b[p]`,
    /// with indices wrapping around, for every shift `s = (sx, sy)`, stored
    /// row-major at `sy * width + sx`. Computed as
    /// `inverseFFT(FFT(a) * conj(FFT(b)))`. `nil` if the sizes aren't
    /// powers of two or don't match the arrays.
    static func circularCrossCorrelation(_ a: [Double], _ b: [Double], width: Int, height: Int) -> [Double]? {
        let count = width * height
        guard isPowerOfTwo(width), isPowerOfTwo(height), a.count == count, b.count == count else { return nil }

        var aReal = a
        var aImaginary = [Double](repeating: 0, count: count)
        var bReal = b
        var bImaginary = [Double](repeating: 0, count: count)
        transform2D(&aReal, &aImaginary, width: width, height: height, inverse: false)
        transform2D(&bReal, &bImaginary, width: width, height: height, inverse: false)

        // (ar + i*ai) * (br - i*bi), reusing a's storage for the product.
        for i in 0..<count {
            let real = aReal[i] * bReal[i] + aImaginary[i] * bImaginary[i]
            let imaginary = aImaginary[i] * bReal[i] - aReal[i] * bImaginary[i]
            aReal[i] = real
            aImaginary[i] = imaginary
        }
        transform2D(&aReal, &aImaginary, width: width, height: height, inverse: true)
        return aReal
    }
}
