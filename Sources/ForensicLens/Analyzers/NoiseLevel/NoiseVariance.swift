/// Turns a `NoiseResidual` high-pass response into an estimate of the
/// noise it came from, on the scale of the image's own gray levels.
///
/// Two estimates, for two jobs:
///
/// - `energyVariance`: the mean squared response divided by
///   `NoiseResidual.maskNorm` squared. For independent noise of variance
///   `v` this is an unbiased estimate of `v`, and for known inputs it can be
///   computed exactly, which is what makes it easy to test. But every edge
///   or patch of texture in a block adds to it.
/// - `robustSigma`: the median absolute response, scaled to a standard
///   deviation (`1.4826 * median|r|` is the standard deviation of Gaussian
///   noise) and divided by `maskNorm`. Up to half a block's pixels can be
///   edges or texture without moving it much. This is the estimate the
///   noise-level map compares blocks with.
///
/// Both return `nil` for an empty residual, so a block too small to have
/// any can be reported as unmeasured rather than as noiseless.
enum NoiseVariance {
    /// Converts a median absolute deviation into a standard deviation for
    /// Gaussian data: `1 / Phi^-1(3/4)`.
    static let madToSigma = 1.482_602_218_505_602

    /// Mean squared residual over `maskNorm` squared: the noise variance,
    /// in squared gray levels, if the residual is noise alone.
    static func energyVariance(of residual: [Double]) -> Double? {
        guard !residual.isEmpty else { return nil }
        let energy = residual.reduce(0.0) { $0 + $1 * $1 }
        return energy / Double(residual.count) / (NoiseResidual.maskNorm * NoiseResidual.maskNorm)
    }

    /// Median-based noise standard deviation, in gray levels.
    static func robustSigma(of residual: [Double]) -> Double? {
        var magnitudes = residual.map { abs($0) }
        guard let median = median(selectingIn: &magnitudes) else { return nil }
        return madToSigma * median / NoiseResidual.maskNorm
    }

    /// The median of `values` (the mean of the two middle values for an
    /// even count), found by quickselect in linear expected time instead of
    /// a full sort; `values` is reordered. This is the per-block hot spot of
    /// the noise-level check: a 64px block has 4096 residual samples, and
    /// sorting them cost more than everything else the check does.
    static func median(selectingIn values: inout [Double]) -> Double? {
        let count = values.count
        guard count > 0 else { return nil }
        let upper = count / 2
        select(&values, k: upper)
        guard count % 2 == 0 else { return values[upper] }
        // After selection everything before `upper` is <= it, so the
        // lower middle value is the largest of those.
        var lower = values[0]
        for i in 1..<upper where values[i] > lower { lower = values[i] }
        return 0.5 * (lower + values[upper])
    }

    /// Reorders `values` so the element at `k` is the one a sort would put
    /// there, with nothing larger before it and nothing smaller after it.
    private static func select(_ values: inout [Double], k: Int) {
        var low = 0
        var high = values.count - 1
        while low < high {
            // Median of three as the pivot keeps sorted and constant runs
            // (a flat block's residual is all zeros) from going quadratic.
            let mid = low + (high - low) / 2
            if values[mid] < values[low] { values.swapAt(mid, low) }
            if values[high] < values[low] { values.swapAt(high, low) }
            if values[high] < values[mid] { values.swapAt(high, mid) }
            let pivot = values[mid]

            var i = low
            var j = high
            while i <= j {
                while values[i] < pivot { i += 1 }
                while values[j] > pivot { j -= 1 }
                if i <= j {
                    values.swapAt(i, j)
                    i += 1
                    j -= 1
                }
            }
            if k <= j {
                high = j
            } else if k >= i {
                low = i
            } else {
                return
            }
        }
    }
}
