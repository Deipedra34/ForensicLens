/// Combines the two AI-generation signals, spectral upsampling artifacts
/// and the absence of a camera sensor-noise fingerprint, into one
/// "signals consistent with AI generation" likelihood and a finding score.
///
/// Kept apart from both detectors and from the analyzer so the rule can be
/// read, configured and tested on its own.
///
/// **The rule.** With `s` the spectral-artifact signal and `a` the
/// PRNU-absence signal, both 0 to 1:
///
/// `likelihood = min(s, a) + singleSignalWeight * (max(s, a) - min(s, a))`
///
/// The weaker of the two signals sets a floor, and the stronger one adds
/// `singleSignalWeight` (0 to 1) of whatever it has beyond that. So:
///
/// - `singleSignalWeight = 0` (**the default**): both signals must agree.
///   The likelihood is `min(s, a)`; one signal on its own contributes
///   nothing.
/// - `singleSignalWeight = 0.5`: the plain average of the two.
/// - `singleSignalWeight = 1`: either signal suffices; the likelihood is
///   `max(s, a)`.
///
/// **Why "both must agree" by default.** Each signal on its own has
/// common, innocent explanations. Strong lattice-frequency peaks also come
/// from JPEG's 8x8 block grid, a camera's color-filter-array demosaicing,
/// resampling, and genuinely periodic scenes (fabric, fences, screens).
/// Missing sensor noise also describes screenshots, graphics, scans,
/// heavily compressed or denoised photos, and downscaled web copies. What
/// those don't usually do is *both*: carry upsampling-lattice peaks while
/// lacking sensor noise everywhere. Raising `singleSignalWeight` trades
/// that robustness for sensitivity to generators that leave only one of
/// the two traces.
///
/// A signal that couldn't be measured (too small or flat an image) enters
/// as 0, so missing data never adds evidence.
enum AIGenerationScore {
    /// The finding score for a likelihood of 1: "likely manipulated" on
    /// `SuspicionScorer`'s scale, but kept below the 90s that conclusive
    /// detectors (an exact clone match) can reach, because this is
    /// statistical evidence about how an image was made, never proof.
    static let maximumFindingScore = 75.0

    /// The default `singleSignalWeight`: both signals must agree.
    static let defaultSingleSignalWeight = 0.0

    /// The combined likelihood, 0 to 1, under the rule in this type's doc
    /// comment. Inputs and the weight are clamped to 0...1; non-finite
    /// values count as 0.
    static func likelihood(spectral: Double, prnuAbsence: Double, singleSignalWeight: Double) -> Double {
        let s = unit(spectral)
        let a = unit(prnuAbsence)
        let weight = unit(singleSignalWeight)
        let low = min(s, a)
        let high = max(s, a)
        return low + weight * (high - low)
    }

    /// The `AnalyzerFinding` score for `likelihood`: linear, up to
    /// `maximumFindingScore`.
    static func findingScore(likelihood: Double) -> Double {
        unit(likelihood) * maximumFindingScore
    }

    private static func unit(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : 0
    }
}
