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
        guard let median = PRNUCorrelation.median(residual.map { abs($0) }) else { return nil }
        return madToSigma * median / NoiseResidual.maskNorm
    }
}
