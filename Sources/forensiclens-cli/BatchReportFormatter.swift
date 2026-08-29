import Foundation

/// Output formats the `batch` command can render a `BatchReport` as.
enum BatchOutputFormat: String {
    case text
    case json
    case csv
}

/// Renders a `BatchReport` into one of `BatchOutputFormat`'s text
/// representations.
///
/// Kept separate from `BatchReport` itself so the report model doesn't
/// need to know anything about column widths, JSON key names, or CSV
/// escaping -- adding a fourth output format later just means adding a
/// case here.
enum BatchReportFormatter {
    static func render(_ report: BatchReport, as format: BatchOutputFormat) throws -> String {
        switch format {
        case .text: return renderText(report)
        case .json: return try renderJSON(report)
        case .csv: return renderCSV(report)
        }
    }

    // MARK: - Text

    private static func renderText(_ report: BatchReport) -> String {
        var lines: [String] = []
        lines.append("ForensicLens Batch Report -- \(report.directory)")
        lines.append(String(repeating: "=", count: 26 + report.directory.count))
        lines.append("\(report.entries.count) file(s) found -- \(report.analyzedCount) analyzed, \(report.skippedCount) skipped")
        lines.append("")

        guard !report.entries.isEmpty else {
            lines.append("No files to report.")
            return lines.joined(separator: "\n")
        }

        let scoreColumnWidth = 8 // fits "100/100" and "SKIPPED" with a trailing space to spare
        lines.append("\("SCORE".padding(toLength: scoreColumnWidth, withPad: " ", startingAt: 0))  FILE")
        for entry in report.entries {
            let scoreText: String
            let detail: String
            if let score = entry.score {
                scoreText = "\(Int(score.rounded()))/100"
                detail = entry.topContributors.isEmpty
                    ? (entry.verdict ?? "no anomalies found")
                    : entry.topContributors.joined(separator: ", ")
            } else {
                scoreText = "SKIPPED"
                detail = entry.skipReason ?? "unknown reason"
            }
            lines.append("\(scoreText.padding(toLength: scoreColumnWidth, withPad: " ", startingAt: 0))  \(entry.filePath)")
            lines.append("\(String(repeating: " ", count: scoreColumnWidth))  \(detail)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - JSON

    private struct JSONEntry: Codable {
        let filePath: String
        let status: String
        let score: Double?
        let verdict: String?
        let topContributors: [String]
        let skipReason: String?
    }

    private struct JSONReport: Codable {
        let directory: String
        let totalFiles: Int
        let analyzedCount: Int
        let skippedCount: Int
        let entries: [JSONEntry]
    }

    private static func renderJSON(_ report: BatchReport) throws -> String {
        let entries = report.entries.map { entry in
            JSONEntry(
                filePath: entry.filePath,
                status: entry.skipReason == nil ? "analyzed" : "skipped",
                score: entry.score,
                verdict: entry.verdict,
                topContributors: entry.topContributors,
                skipReason: entry.skipReason
            )
        }
        let payload = JSONReport(
            directory: report.directory,
            totalFiles: report.entries.count,
            analyzedCount: report.analyzedCount,
            skippedCount: report.skippedCount,
            entries: entries
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - CSV

    private static func renderCSV(_ report: BatchReport) -> String {
        var lines = ["file_path,status,score,verdict,top_contributors,skip_reason"]
        for entry in report.entries {
            let row = [
                entry.filePath,
                entry.skipReason == nil ? "analyzed" : "skipped",
                entry.score.map { String(Int($0.rounded())) } ?? "",
                entry.verdict ?? "",
                entry.topContributors.joined(separator: "; "),
                entry.skipReason ?? ""
            ]
            lines.append(row.map(csvField).joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    /// Quotes a CSV field if it contains a comma, quote, or newline (RFC
    /// 4180), doubling any embedded quotes. File paths and skip reasons are
    /// the only fields likely to need this in practice.
    private static func csvField(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else {
            return value
        }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
