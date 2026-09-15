import Foundation
import ImageDecoding

/// The self-contained numerical core `DoubleCompressionAnalyzer` builds on:
/// pulling one DCT coefficient out of every 8x8 luma block in an image, and
/// measuring how periodic that coefficient's histogram is.
///
/// Kept separate from `DoubleCompressionAnalyzer` itself since none of this
/// needs to know anything about `Analyzer`, `ForensicLensConfig`, or
/// scoring -- it's plain numerical analysis of a `PixelBuffer`, the same
/// kind of split `DCT8x8` and `JPEGRecompressionSimulator` already get from
/// `ELAAnalyzer` in this package.
enum DCTPeriodicityAnalysis {
    private static let blockSize = 8

    /// Extracts the DCT coefficient at `(row, col)` from every fully
    /// contained `blockSize` x `blockSize` luma block in `buffer`, with the
    /// block grid's origin shifted to `(offsetX, offsetY)` instead of always
    /// starting at pixel `(0, 0)`.
    ///
    /// A real JPEG's 8x8 block grid is anchored to its own pixel `(0, 0)`.
    /// If the image was cropped in between two compression passes, that
    /// anchor point moves by however many pixels were trimmed off the top
    /// and left -- so re-deriving the *current* file's grid at `(0, 0)`
    /// samples a mix of coefficients from several different blocks of the
    /// original second-pass grid, which washes out the periodicity this
    /// whole analysis is looking for. `DoubleCompressionAnalyzer` tries a
    /// handful of candidate offsets and keeps whichever one produces the
    /// strongest signal, which is what lets this survive an unknown crop
    /// rather than only ever working on uncropped re-saves.
    ///
    /// Any row of pixels short of a full block at the bottom/right edge is
    /// simply left out rather than padded -- there's no way to invent the
    /// missing pixels without biasing the very histogram being measured, so
    /// this only ever samples the largest region that tiles evenly into
    /// full blocks from `(offsetX, offsetY)`.
    static func blockCoefficients(
        in buffer: PixelBuffer,
        row: Int,
        col: Int,
        offsetX: Int,
        offsetY: Int
    ) -> [Double] {
        var values: [Double] = []
        var block = [Double](repeating: 0, count: blockSize * blockSize)

        var by = offsetY
        while by + blockSize <= buffer.height {
            var bx = offsetX
            while bx + blockSize <= buffer.width {
                for y in 0..<blockSize {
                    for x in 0..<blockSize {
                        block[y * blockSize + x] = Double(buffer.luma(x: bx + x, y: by + y)) - 128
                    }
                }
                let coefficients = DCT8x8.forward(block)
                values.append(coefficients[row * blockSize + col])
                bx += blockSize
            }
            by += blockSize
        }
        return values
    }

    /// Bins `values` (rounded to the nearest integer) into a histogram
    /// centered on zero, wide enough to cover every observed value (capped
    /// at `maxRange` so one wild outlier can't spread every other bin's
    /// count paper-thin).
    ///
    /// - Returns: The bin counts, plus the half-width used to build them
    ///   (bin `range` is value 0; bin 0 is value `-range`).
    static func histogram(of values: [Double], maxRange: Int = 200) -> (bins: [Int], range: Int) {
        guard !values.isEmpty else { return ([], 0) }

        let observedMax = values.reduce(0.0) { max($0, abs($1)) }
        let range = max(4, min(maxRange, Int(observedMax.rounded(.up))))

        var bins = [Int](repeating: 0, count: range * 2 + 1)
        for value in values {
            let rounded = Int(value.rounded())
            let clamped = max(-range, min(range, rounded))
            bins[clamped + range] += 1
        }
        return (bins, range)
    }

    /// How strongly `bins` shows the periodic "comb" pattern double JPEG
    /// compression leaves behind, expressed as a 0...1 fraction of spectral
    /// energy concentrated in one dominant frequency.
    ///
    /// Any single quantization step -- whether it's the only one an image
    /// went through, or just the last of several -- already restricts a
    /// coefficient to multiples of that one step, which makes bin *presence*
    /// (whether a given value is reachable at all) periodic even after a
    /// single compression. That's not the tell this function is after: it's
    /// exactly as true for one compression pass as for two, so treating it
    /// as "the" periodicity would flag every JPEG. The actual double-
    /// compression signature Popescu & Farid, and separately Lin et al.,
    /// describe is subtler: it's in how *unevenly populated* those reachable
    /// bins are relative to each other. Quantizing a coefficient a second
    /// time at a different step requantizes values that are already
    /// multiples of the first step, and because the two steps don't
    /// generally share a common multiple, some final bins end up reachable
    /// from more first-pass values than their neighbors -- a periodic
    /// pattern of relatively fat and thin bins among the reachable ones,
    /// riding on top of whatever smooth envelope the coefficient's natural
    /// distribution has. A single compression's reachable bins just sample
    /// that smooth envelope evenly, with no such alternation.
    ///
    /// So this only ever looks at the *non-empty* bins, in order, discarding
    /// the always-empty gaps between them -- those gaps carry the trivial
    /// "one quantization step happened" signal this function isn't
    /// interested in, not the "how many happened" signal it is. It then
    /// removes the smooth envelope the same way from that reduced sequence:
    /// subtracting a small local moving average cancels the slow-moving
    /// hump, leaving only short-period ripples. A discrete Fourier transform
    /// of that residual turns a genuine bin-population comb into one
    /// clearly dominant non-zero frequency; a once-compressed histogram's
    /// now-flattened residual has nothing to concentrate and spreads
    /// whatever's left across many frequencies instead.
    static func periodicityStrength(of bins: [Int]) -> Double {
        let populated = bins.filter { $0 > 0 }
        let n = populated.count
        guard n >= 8 else { return 0 }

        let windowRadius = 3
        var residual = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let lo = max(0, i - windowRadius)
            let hi = min(n - 1, i + windowRadius)
            let localMean = (lo...hi).reduce(0.0) { $0 + Double(populated[$1]) } / Double(hi - lo + 1)
            residual[i] = Double(populated[i]) - localMean
        }

        // Only frequencies 1...n/2 are unique for a real-valued signal
        // (frequency 0, the residual's own mean, is ~0 by construction).
        let maxFrequency = n / 2
        guard maxFrequency >= 2 else { return 0 }

        var magnitudes = [Double](repeating: 0, count: maxFrequency + 1)
        for frequency in 1...maxFrequency {
            var real = 0.0
            var imaginary = 0.0
            for k in 0..<n {
                let angle = -2.0 * Double.pi * Double(frequency) * Double(k) / Double(n)
                real += residual[k] * cos(angle)
                imaginary += residual[k] * sin(angle)
            }
            magnitudes[frequency] = (real * real + imaginary * imaginary).squareRoot()
        }

        let totalEnergy = magnitudes.reduce(0, +)
        guard totalEnergy > 0 else { return 0 }
        let peak = magnitudes.max() ?? 0
        return peak / totalEnergy
    }
}
