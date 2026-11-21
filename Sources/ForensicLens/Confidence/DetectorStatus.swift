/// What an analyzer's finding says about whether it could judge the image
/// at all, read from the finding itself.
///
/// Analyzers don't carry an explicit "applicable" flag: a check that doesn't
/// apply, or couldn't reach an answer, reports a clean finding (score 0)
/// and says why in its summary, and the engine turns an analyzer that threw
/// into a "Could not run ..." finding. Confidence calibration needs to tell
/// those apart from a genuine "looked and found nothing", because only the
/// latter is evidence. This reads that distinction from the existing
/// findings without changing what any analyzer reports.
public enum DetectorStatus: String, Sendable, Codable, CaseIterable {
    /// The analyzer examined the image and scored something (score > 0).
    case flagged
    /// The analyzer examined the image and found nothing unusual.
    case clean
    /// The analyzer doesn't apply to this kind of input: a JPEG-specific
    /// check on a HEIC or WebP file, a color check on a grayscale image, a
    /// thumbnail check on a file without one.
    case notApplicable
    /// The analyzer applies, but couldn't reach a reliable answer: the image
    /// is too small, flat, clipped, or has too few usable blocks.
    case notAssessed
    /// The analyzer couldn't run at all (for example, it needs decoded
    /// pixels and the format's pixels can't be decoded yet).
    case failed

    /// Whether the finding counts as evidence, either way. Only flagged and
    /// clean findings do; the other three say nothing about the image.
    public var isAssessed: Bool {
        self == .flagged || self == .clean
    }

    /// The status of `finding`.
    ///
    /// The rule, in order: a summary starting with "Could not run" (the
    /// engine's wording for an analyzer that threw) is `failed`; any score
    /// above 0 is `flagged`; a score-0 summary using one of the analyzers'
    /// not-applicable phrasings is `notApplicable`, one using a
    /// not-assessed phrasing (too small, nothing to compare, not assessed,
    /// ...) is `notAssessed`; anything else is `clean`.
    public static func classify(_ finding: AnalyzerFinding) -> DetectorStatus {
        let summary = finding.summary.lowercased()
        if summary.hasPrefix("could not run") {
            return .failed
        }
        if finding.score > 0 {
            return .flagged
        }
        if notApplicableMarkers.contains(where: { summary.contains($0) }) {
            return .notApplicable
        }
        if notAssessedMarkers.contains(where: { summary.contains($0) }) {
            return .notAssessed
        }
        return .clean
    }

    /// Phrases analyzers use when they don't apply to an input.
    static let notApplicableMarkers = ["not applicable", "does not carry exif", "nothing to analyze"]

    /// Phrases analyzers use when they apply but couldn't judge the input.
    static let notAssessedMarkers = ["not assessed", "too small", "nothing to compare", "no measurable", "inconclusive", "was not run", "skipped", "low confidence"]
}
