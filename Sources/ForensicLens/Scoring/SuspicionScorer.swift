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

    public init(overallScore: Double, verdict: String, findings: [AnalyzerFinding]) {
        self.overallScore = overallScore
        self.verdict = verdict
        self.findings = findings
    }

    /// Renders the report as an itemized, human-readable block of text
    /// suitable for direct terminal output.
    public var textReport: String {
        var lines: [String] = []
        lines.append("ForensicLens Report")
        lines.append("====================")
        lines.append("Overall suspicion score: \(Int(overallScore.rounded()))/100 (\(verdict))")
        lines.append("")

        for finding in findings {
            lines.append("[\(finding.analyzerID)] score \(Int(finding.score.rounded()))/100 -- \(finding.summary)")
            for indicator in finding.indicators {
                lines.append("  - \(indicator.message)")
            }
        }

        return lines.joined(separator: "\n")
    }
}

/// Combines every enabled analyzer's `AnalyzerFinding` into a single 0...100
/// manipulation suspicion score and a human-readable report.
///
/// **Why a weighted maximum instead of a plain average.** Averaging the
/// three analyzer scores would let a single strong signal get diluted by
/// two analyzers that simply found nothing to say -- an image with an
/// unambiguous copy-move match scoring 95 on clone detection shouldn't drop
/// to a lukewarm ~32 just because ELA and metadata had nothing unusual to
/// report on a small BMP with no EXIF at all. `SuspicionScorer` instead
/// takes the strongest single finding as the dominant signal and lets the
/// other analyzers nudge the score up when they corroborate it, which
/// matches how a human reviewer would actually reason about multiple
/// independent pieces of evidence: one solid finding is often enough, and
/// agreement between methods is reinforcing rather than strictly additive.
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

    private static func verdict(for score: Double) -> String {
        switch score {
        case ..<20: return "likely authentic"
        case ..<45: return "minor anomalies"
        case ..<70: return "suspicious"
        default: return "likely manipulated"
        }
    }
}
