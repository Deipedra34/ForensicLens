import Foundation
import ForensicLens

/// The HTML for a report's calibrated confidence and plain-language
/// explanation: a "What this means" card above the per-analyzer findings,
/// and a calibration table below them. Markup only -- every sentence comes
/// from `ReportExplanation`, every number from `CalibratedConfidence` --
/// and every piece of text is escaped, since findings can quote text taken
/// from the image's own metadata.
enum HTMLExplanation {
    /// The "What this means" card, or an empty string for a report with
    /// neither a confidence nor an explanation.
    static func card(for report: ForensicReport) -> String {
        guard report.confidence != nil || report.explanation != nil else { return "" }
        var parts: [String] = ["<section class=\"card explanation\" id=\"explanation\">", "<h2>What this means</h2>"]

        if let confidence = report.confidence {
            let severity = HTMLTemplate.severityClass(confidence.score)
            parts.append("<p class=\"calibrated\">Calibrated confidence: <strong class=\"\(severity)\" id=\"calibrated-score\" data-score=\"\(number(confidence.score))\">\(number(confidence.score))/100</strong> (\(HTMLTemplate.escape(confidence.verdict))) <span class=\"muted\">&middot; \(confidence.assessedDetectors) of \(confidence.totalDetectors) checks could examine this image</span></p>")
        }

        if let explanation = report.explanation {
            parts.append("<p class=\"headline\">\(HTMLTemplate.escape(explanation.headline))</p>")
            parts.append("<p>\(HTMLTemplate.escape(explanation.summary))</p>")
            if !explanation.keyFindings.isEmpty {
                parts.append("<h3>Key findings</h3>")
                parts.append(list(explanation.keyFindings.map(\.text), className: "key-findings"))
            }
            if !explanation.caveats.isEmpty {
                parts.append("<h3>Keep in mind</h3>")
                parts.append(list(explanation.caveats, className: "caveats"))
            }
            if !explanation.walkthrough.isEmpty {
                parts.append("<details class=\"walkthrough\"><summary>Check by check</summary>")
                parts.append(list(explanation.walkthrough.map(\.text), className: "walkthrough-list"))
                parts.append("</details>")
            }
        }

        parts.append("</section>")
        return parts.joined(separator: "\n")
    }

    /// The calibration arithmetic as a table, or an empty string for a
    /// report without a calibrated confidence.
    static func calibrationTable(for report: ForensicReport) -> String {
        guard let confidence = report.confidence else { return "" }
        let rows = confidence.contributions.map { contribution -> String in
            let counted = contribution.status == .flagged
            let cells = [
                "<td>\(HTMLTemplate.escape(contribution.analyzerID))</td>",
                "<td>\(HTMLTemplate.escape(contribution.status.rawValue))</td>",
                "<td class=\"num\">\(number(contribution.rawScore))</td>",
                "<td class=\"num\">\(counted ? String(format: "%.2f", contribution.normalizedStrength) : "&ndash;")</td>",
                "<td class=\"num\">\(String(format: "%.2f", contribution.reliability))</td>",
                "<td class=\"num\">\(counted ? String(format: "%.2f", contribution.evidence) : "&ndash;")</td>",
            ]
            return "<tr data-analyzer=\"\(HTMLTemplate.escape(contribution.analyzerID))\">\(cells.joined())</tr>"
        }
        let agreements = confidence.agreements.map { agreement -> String in
            let region = agreement.region
            let ids = agreement.analyzerIDs.map(HTMLTemplate.escape).joined(separator: " + ")
            let applied = agreement.applied ? "" : " <span class=\"muted\">(not applied: only the strongest agreement counts)</span>"
            return "<li>\(ids) agree at x \(region.x)-\(region.x + region.width), y \(region.y)-\(region.y + region.height): boost \(String(format: "%.3f", agreement.boost))\(applied)</li>"
        }
        let agreementList = agreements.isEmpty ? "" : "\n<ul class=\"agreements\">\n\(agreements.joined(separator: "\n"))\n</ul>"

        return """
        <h2>Calibration</h2>
        <section class="card calibration">
        <p class="muted">Each check's score is divided by the highest score it can produce, weighted by how prone it is to false positives, and combined as 1 &minus; &prod;(1 &minus; evidence); independent checks agreeing on one area add a boost.</p>
        <table>
        <thead><tr><th>Check</th><th>Status</th><th>Raw score</th><th>Normalized</th><th>Reliability</th><th>Evidence</th></tr></thead>
        <tbody>
        \(rows.joined(separator: "\n"))
        </tbody>
        </table>\(agreementList)
        <p>Combined: <strong>\(number(confidence.score))/100</strong> (\(HTMLTemplate.escape(confidence.verdict)))</p>
        </section>
        """
    }

    static func list(_ items: [String], className: String) -> String {
        "<ul class=\"\(className)\">\n" + items.map { "<li>\(HTMLTemplate.escape($0))</li>" }.joined(separator: "\n") + "\n</ul>"
    }

    /// One decimal, without a trailing ".0".
    static func number(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
    }

    static let style = """
    .explanation { margin: 20px 0 12px; }
    .explanation h2 { margin-top: 0; }
    .explanation h3 { font-size: 1rem; margin: 14px 0 6px; }
    .explanation .calibrated { font-size: 1.1rem; }
    .explanation .headline { font-weight: 600; font-size: 1.05rem; }
    .explanation ul { margin: 0; padding-left: 20px; }
    .explanation li { margin-bottom: 6px; }
    .walkthrough { margin-top: 12px; }
    .walkthrough summary { cursor: pointer; font-weight: 600; }
    .calibration table { border-collapse: collapse; width: 100%; font-size: 0.9rem; }
    .calibration th, .calibration td { text-align: left; padding: 4px 8px; border-bottom: 1px solid var(--border); }
    .calibration td.num { text-align: right; font-variant-numeric: tabular-nums; }
    .agreements { margin: 10px 0 0; padding-left: 20px; }
    """
}
