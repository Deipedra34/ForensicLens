/// The complete result of running one or more analyzers against an image.
public struct ForensicReport: Sendable, Equatable, Codable {
    /// Combined 0...100 manipulation suspicion score. See
    /// `SuspicionScorer.score(_:)` for how per-analyzer scores are combined.
    public let overallScore: Double

    /// A short, human-readable verdict derived from `overallScore`.
    public let verdict: String

    /// Every analyzer finding that went into `overallScore`, in the order
    /// the analyzers ran.
    public let findings: [AnalyzerFinding]

    /// The calibrated confidence built from `findings` (see
    /// `ConfidenceCalibrator`): detectors normalized to one scale, weighted
    /// by how prone they are to false positives, and boosted where
    /// independent ones agree. Set on every report `ForensicLensEngine`
    /// produces; `nil` on a report built directly by `SuspicionScorer`.
    /// `overallScore` is unchanged by it, so thresholds built on the
    /// suspicion score keep working.
    public var confidence: CalibratedConfidence?

    /// The plain-language explanation of the findings (see
    /// `NarrativeGenerator`). `nil` when the narrative is turned off
    /// (`report.narrative: false`) or the report wasn't explained.
    public var explanation: ReportExplanation?

    public init(overallScore: Double, verdict: String, findings: [AnalyzerFinding], confidence: CalibratedConfidence? = nil, explanation: ReportExplanation? = nil) {
        self.overallScore = overallScore
        self.verdict = verdict
        self.findings = findings
        self.confidence = confidence
        self.explanation = explanation
    }

    /// Renders the report as a human-readable block of text suitable for
    /// direct terminal output (and valid Markdown): the scores, the
    /// plain-language explanation when there is one, then every finding
    /// and the calibration arithmetic as technical details. See
    /// `ReportTextRenderer`.
    public var textReport: String {
        ReportTextRenderer.render(self)
    }
}

/// Combines every enabled analyzer's `AnalyzerFinding` into a single 0...100
/// manipulation suspicion score and a human-readable report.
///
/// Why not just average the three scores together? Because it would let a
/// single strong signal get watered down by analyzers that simply had
/// nothing to say. An image with an unambiguous copy-move match scoring 95
/// on clone detection shouldn't drop to a lukewarm ~32 just because ELA and
/// metadata found nothing unusual on a small BMP with no EXIF to begin
/// with. So instead, `SuspicionScorer` takes the strongest single finding
/// as the dominant signal and lets the other analyzers nudge the score up
/// when they back it up. That's closer to how a human reviewer actually
/// weighs a pile of independent evidence anyway: one solid finding is
/// often enough on its own, and agreement between methods reinforces it
/// rather than just adding up.
public struct SuspicionScorer: Sendable {
    /// How much weight each additional corroborating analyzer contributes,
    /// on top of the dominant score. Kept modest so two weak, borderline
    /// findings don't combine into a falsely confident verdict.
    private static let corroborationWeight = 0.15

    public init() {}

    /// Combines `findings` into a complete `ForensicReport`.
    public func score(_ findings: [AnalyzerFinding]) -> ForensicReport {
        guard !findings.isEmpty else {
            return ForensicReport(overallScore: 0, verdict: Self.verdict(for: 0), findings: [])
        }

        let sorted = findings.sorted { $0.score > $1.score }
        let dominant = sorted[0].score
        let corroboration = sorted.dropFirst().reduce(0.0) { $0 + $1.score * Self.corroborationWeight }

        let overall = min(100, dominant + corroboration)
        return ForensicReport(overallScore: overall, verdict: Self.verdict(for: overall), findings: findings)
    }

    /// The verdict band for a 0...100 score. Shared with
    /// `ConfidenceCalibrator`, so the calibrated confidence reads on the same
    /// bands as the suspicion score.
    static func verdict(for score: Double) -> String {
        switch score {
        case ..<20: return "likely authentic"
        case ..<45: return "minor anomalies"
        case ..<70: return "suspicious"
        default: return "likely manipulated"
        }
    }
}
