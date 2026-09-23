/// One generated per-image report, as listed on a batch `index.html`.
public struct HTMLReportIndexEntry: Sendable, Equatable {
    /// Link target for this entry's report, relative to `index.html`.
    public let reportHref: String
    /// The analyzed image's path, as shown to the reader.
    public let sourcePath: String
    public let score: Double
    public let verdict: String

    public init(reportHref: String, sourcePath: String, score: Double, verdict: String) {
        self.reportHref = reportHref
        self.sourcePath = sourcePath
        self.score = score
        self.verdict = verdict
    }
}

/// Renders the `index.html` that sits next to a batch run's per-image
/// HTML reports, listing every one of them, most suspicious first.
public enum HTMLReportIndex {
    /// - Parameters:
    ///   - entries: Every report written during the batch, in any order;
    ///     they're sorted here (score descending, then path) so the page's
    ///     ordering never depends on which analyses happened to finish
    ///     first.
    ///   - directory: The batch's scanned directory, shown in the header.
    ///   - threshold: The score an image had to exceed to get a report.
    public static func render(entries: [HTMLReportIndexEntry], directory: String, threshold: Double) -> String {
        let sorted = sortedEntries(entries)
        let body = [
            header(directory: directory, count: sorted.count, threshold: threshold),
            table(sorted),
        ].joined(separator: "\n")

        return HTMLTemplate.document(title: "ForensicLens Batch Report", extraStyle: style, body: body)
    }

    static func sortedEntries(_ entries: [HTMLReportIndexEntry]) -> [HTMLReportIndexEntry] {
        entries.sorted { lhs, rhs in
            lhs.score != rhs.score ? lhs.score > rhs.score : lhs.sourcePath < rhs.sourcePath
        }
    }

    // MARK: - Page pieces

    static func header(directory: String, count: Int, threshold: Double) -> String {
        """
        <header class="card">
        <h1>ForensicLens Batch Report</h1>
        <p class="path">\(HTMLTemplate.escape(directory))</p>
        <p class="muted">\(count) image\(count == 1 ? "" : "s") scored above \(HTMLTemplate.escape(thresholdText(threshold))), sorted by suspicion score (highest first).</p>
        </header>
        """
    }

    static func table(_ entries: [HTMLReportIndexEntry]) -> String {
        guard !entries.isEmpty else {
            return "<p class=\"card no-reports\">No images scored above the threshold, so no reports were generated.</p>"
        }

        let rows = entries.map { entry -> String in
            let severity = HTMLTemplate.severityClass(entry.score)
            return "<tr class=\"report-row\"><td class=\"score-cell \(severity)\">\(HTMLTemplate.scoreText(entry.score))/100</td><td class=\"\(severity)\">\(HTMLTemplate.escape(entry.verdict))</td><td><a class=\"path\" href=\"\(HTMLTemplate.escape(entry.reportHref))\">\(HTMLTemplate.escape(entry.sourcePath))</a></td></tr>"
        }

        return """
        <table class="card">
        <thead><tr><th>Score</th><th>Verdict</th><th>Image</th></tr></thead>
        <tbody>
        \(rows.joined(separator: "\n"))
        </tbody>
        </table>
        """
    }

    /// `0` -> "0", `12.5` -> "12.5": whole thresholds read as whole numbers.
    static func thresholdText(_ threshold: Double) -> String {
        threshold.isFinite && threshold.rounded() == threshold && abs(threshold) < 1e15 ? String(Int(threshold)) : String(threshold)
    }

    static let style = """
    header.card { margin-bottom: 20px; }
    header .path { margin: 0 0 4px; }
    header p.muted { margin: 0; }
    table { width: 100%; border-collapse: collapse; padding: 0; }
    th, td { text-align: left; padding: 10px 14px; border-bottom: 1px solid var(--border); vertical-align: top; }
    tbody tr:last-child td { border-bottom: none; }
    th { font-size: 0.8rem; text-transform: uppercase; letter-spacing: 0.04em; color: var(--muted); }
    .score-cell { font-weight: 700; font-variant-numeric: tabular-nums; white-space: nowrap; }
    td a { color: inherit; }
    """
}
