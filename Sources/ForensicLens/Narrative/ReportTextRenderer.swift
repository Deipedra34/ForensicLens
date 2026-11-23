import Foundation

/// Renders a `ForensicReport` as plain text for the terminal.
///
/// The layout is also valid Markdown (underlined headings, `-` bullets), so
/// the same text can be pasted into an issue, a ticket, or a Markdown file.
/// Formatting only: every sentence comes from the report's `explanation`
/// and every number from its findings and `confidence`.
///
/// A report with neither a confidence nor an explanation renders exactly
/// as reports always have: the suspicion score and one line per finding.
enum ReportTextRenderer {
    static func render(_ report: ForensicReport) -> String {
        var lines: [String] = []
        lines.append("ForensicLens Report")
        lines.append("====================")
        lines.append("Overall suspicion score: \(Int(report.overallScore.rounded()))/100 (\(report.verdict))")
        if let confidence = report.confidence {
            lines.append("Calibrated confidence: \(score(confidence.score))/100 (\(confidence.verdict)) -- \(confidence.assessedDetectors) of \(confidence.totalDetectors) checks could examine this image")
        }
        lines.append("")

        if let explanation = report.explanation {
            lines += narrative(explanation)
            lines.append("")
        }
        if report.explanation != nil || report.confidence != nil {
            lines.append("Technical details")
            lines.append("-----------------")
        }

        for finding in report.findings {
            lines.append("[\(finding.analyzerID)] score \(Int(finding.score.rounded()))/100 -- \(finding.summary)")
            for indicator in finding.indicators {
                lines.append("  - \(indicator.message)")
            }
        }

        if let confidence = report.confidence {
            lines.append("")
            lines += calibration(confidence)
        }
        return lines.joined(separator: "\n")
    }

    /// "What this means": headline, summary, key findings, caveats, and at
    /// full verbosity the check-by-check walkthrough.
    static func narrative(_ explanation: ReportExplanation) -> [String] {
        var lines = ["What this means", "---------------", explanation.headline, "", explanation.summary]
        if !explanation.keyFindings.isEmpty {
            lines += ["", "Key findings:"] + explanation.keyFindings.map { "  - \($0.text)" }
        }
        if !explanation.caveats.isEmpty {
            lines += ["", "Keep in mind:"] + explanation.caveats.map { "  - \($0)" }
        }
        if !explanation.walkthrough.isEmpty {
            lines += ["", "Check by check:"] + explanation.walkthrough.map { "  - \($0.text)" }
        }
        return lines
    }

    /// The calibration arithmetic, one line per detector, then any region
    /// agreements and the combined result.
    static func calibration(_ confidence: CalibratedConfidence) -> [String] {
        var lines = ["Calibration (raw score -> normalized strength x reliability = evidence):"]
        let idWidth = max(8, confidence.contributions.map(\.analyzerID.count).max() ?? 0)
        for contribution in confidence.contributions {
            let id = contribution.analyzerID.padding(toLength: idWidth, withPad: " ", startingAt: 0)
            let status = contribution.status.rawValue.padding(toLength: 13, withPad: " ", startingAt: 0)
            let raw = String(format: "%5.1f", contribution.rawScore)
            switch contribution.status {
            case .flagged:
                lines.append("  \(id)  \(status)  \(raw) -> \(String(format: "%.2f", contribution.normalizedStrength)) x \(String(format: "%.2f", contribution.reliability)) = \(String(format: "%.2f", contribution.evidence))")
            case .clean:
                // Assessed, and found nothing: no evidence, but it counts
                // toward how many checks could examine the image.
                lines.append("  \(id)  \(status)  \(raw) -> no evidence (found nothing)")
            case .notApplicable, .notAssessed, .failed:
                lines.append("  \(id)  \(status)  \(raw) -> not counted")
            }
        }
        for agreement in confidence.agreements {
            let region = agreement.region
            let place = "x \(region.x)-\(region.x + region.width), y \(region.y)-\(region.y + region.height)"
            let families = agreement.families.map(\.rawValue).joined(separator: ", ")
            let applied = agreement.applied ? "" : " (not applied: only the strongest agreement counts)"
            lines.append("  Agreement: \(agreement.analyzerIDs.joined(separator: " + ")) at \(place) [\(families)] boost \(String(format: "%.3f", agreement.boost))\(applied)")
        }
        lines.append("  Combined: 1 - product(1 - evidence) = \(score(confidence.score))/100 (\(confidence.verdict))")
        return lines
    }

    /// One decimal, without a trailing ".0".
    static func score(_ value: Double) -> String {
        NarrativeGenerator.formatted(value)
    }
}
