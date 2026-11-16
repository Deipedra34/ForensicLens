import Foundation

/// Which way a block's noise level departs from the rest of the image.
/// The two directions suggest different things, so they're reported
/// separately.
public enum NoiseDeviationDirection: String, Sendable, Equatable, Codable {
    /// Less noise than the image's typical level: a denoised, blurred,
    /// smoothed, or synthetic (rendered, painted) region, or one pasted
    /// from a cleaner, lower-ISO source.
    case tooSmooth
    /// More noise than the image's typical level: a region pasted from a
    /// noisier source (higher ISO, smaller sensor, heavier compression), or
    /// with noise added to hide an edit.
    case tooNoisy
}

/// The image's own typical noise level, against which every block is
/// compared, and how much blocks normally vary around it.
///
/// Both are robust statistics, so a spliced region covering less than half
/// the image can't drag the baseline toward itself: the median block noise
/// level, and the median absolute deviation of every block's log ratio to
/// it (scaled to a standard deviation). Ratios are compared on a log scale
/// because noise levels are multiplicative: half the typical noise is as
/// far below it as twice is above.
struct NoiseBaseline: Sendable, Equatable {
    /// Median noise standard deviation over the measured blocks, in gray
    /// levels.
    let medianSigma: Double

    /// Robust standard deviation of `ln(sigma / medianSigma)` across the
    /// blocks with any noise at all. Small for an image whose noise is
    /// uniform, larger for one whose noise varies naturally (e.g. with
    /// brightness).
    let logSpread: Double

    /// The baseline of `sigmas` (one per measured block), or `nil` if there
    /// are none or their median is zero: an image with no measurable noise
    /// gives nothing to compare against.
    static func of(_ sigmas: [Double]) -> NoiseBaseline? {
        guard let median = PRNUCorrelation.median(sigmas), median > 0 else { return nil }
        let logRatios = sigmas.filter { $0 > 0 }.map { log($0 / median) }
        let center = PRNUCorrelation.median(logRatios) ?? 0
        let mad = PRNUCorrelation.median(logRatios.map { abs($0 - center) }) ?? 0
        return NoiseBaseline(medianSigma: median, logSpread: NoiseVariance.madToSigma * mad)
    }

    /// `sigma` as a fraction of the typical level: 1 for a typical block.
    func ratio(of sigma: Double) -> Double { sigma / medianSigma }
}

/// Decides whether a block's noise level deviates from the image's, and in
/// which direction. Pure arithmetic on noise levels, kept apart from block
/// walking and scoring so each rule can be tested on its own.
enum NoiseDeviation {
    /// A block must also lie this many robust standard deviations
    /// (`NoiseBaseline.logSpread`) from the typical level to be flagged.
    /// In an image whose blocks naturally vary a lot, this widens the
    /// configured thresholds instead of flagging the ordinary variation.
    static let spreadMultiplier = 3.0

    /// The ratios (block noise / typical noise) outside which a block is
    /// flagged.
    struct Cutoffs: Sendable, Equatable {
        /// Below this ratio a block is too smooth.
        let lower: Double
        /// Above this ratio a block is too noisy.
        let upper: Double
    }

    /// The configured thresholds, kept to sensible ranges: `smooth` within
    /// 0.01...0.99 and `noisy` at least 1.01, so neither can flag a block
    /// whose noise is exactly typical.
    static func clampedThresholds(smooth: Double, noisy: Double) -> (smooth: Double, noisy: Double) {
        (min(0.99, max(0.01, smooth.isFinite ? smooth : 0.5)), max(1.01, noisy.isFinite ? noisy : 2))
    }

    /// The cutoffs for `baseline`: the configured thresholds, widened to at
    /// least `spreadMultiplier` robust standard deviations when the image's
    /// blocks naturally vary more than that.
    static func cutoffs(for baseline: NoiseBaseline, smoothThreshold: Double, noisyThreshold: Double) -> Cutoffs {
        let (smooth, noisy) = clampedThresholds(smooth: smoothThreshold, noisy: noisyThreshold)
        let spread = spreadMultiplier * max(0, baseline.logSpread)
        return Cutoffs(lower: min(smooth, exp(-spread)), upper: max(noisy, exp(spread)))
    }

    /// The direction a block with noise `ratio` deviates in, or `nil` if
    /// it's within the cutoffs. A ratio of 0 (no measurable noise at all,
    /// where the rest of the image has some) is too smooth.
    static func classify(ratio: Double, cutoffs: Cutoffs) -> NoiseDeviationDirection? {
        guard ratio.isFinite, ratio >= 0 else { return nil }
        if ratio < cutoffs.lower { return .tooSmooth }
        if ratio > cutoffs.upper { return .tooNoisy }
        return nil
    }

    /// How far past its cutoff a flagged block lies, from 0 (just past) to
    /// 1. Too smooth: the share of the lower cutoff missing, so a block
    /// with no noise at all scores 1. Too noisy: the log distance past the
    /// upper cutoff, reaching 1 at twice the cutoff.
    static func severity(ratio: Double, direction: NoiseDeviationDirection, cutoffs: Cutoffs) -> Double {
        switch direction {
        case .tooSmooth:
            guard cutoffs.lower > 0 else { return 0 }
            return max(0, min(1, (cutoffs.lower - ratio) / cutoffs.lower))
        case .tooNoisy:
            guard cutoffs.upper > 0, ratio > cutoffs.upper else { return 0 }
            return max(0, min(1, log(ratio / cutoffs.upper) / log(2)))
        }
    }

    /// How close a flagged block's noise must be to what its brightness
    /// alone predicts (as a factor either way) to count as explained by
    /// exposure.
    static let exposureTolerance = 1.5

    /// Whether a flagged block's deviation is what ordinary photon shot
    /// noise would produce at its brightness, rather than a sign of
    /// different content.
    ///
    /// A sensor's shot noise has a variance proportional to the light it
    /// collected, so its standard deviation grows with the square root of
    /// brightness: an untouched photo's shadows are less noisy than its
    /// highlights. A block counts as explained when it's darker than
    /// typical and too smooth (or brighter and too noisy), and its noise
    /// ratio lies within `exposureTolerance` of `sqrt(blockLuma /
    /// typicalLuma)`. Explained blocks are still reported, with less weight:
    /// a splice can happen to land in a shadow, and real sensors add read
    /// noise and tone curves that bend this model. A ratio of 0 (no noise
    /// at all) is never explained, since even the darkest real pixels carry
    /// some.
    static func exposureExplained(ratio: Double, direction: NoiseDeviationDirection, blockLuma: Double, typicalLuma: Double) -> Bool {
        guard ratio > 0, ratio.isFinite, blockLuma.isFinite, typicalLuma.isFinite else { return false }
        let expected = (max(blockLuma, 1) / max(typicalLuma, 1)).squareRoot()
        switch direction {
        case .tooSmooth: guard expected < 1 else { return false }
        case .tooNoisy: guard expected > 1 else { return false }
        }
        let mismatch = ratio / expected
        return mismatch >= 1 / exposureTolerance && mismatch <= exposureTolerance
    }
}
