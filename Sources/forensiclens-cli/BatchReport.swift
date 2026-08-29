import ForensicLens

extension ForensicReport {
    /// The findings that contributed most to `overallScore`: non-zero
    /// scores, strongest first, capped at `limit`.
    ///
    /// Zero-score findings didn't move the overall score at all (see
    /// `SuspicionScorer`), so they're not "contributing" anything worth
    /// surfacing in a one-line batch summary row.
    func topContributors(limit: Int = 3) -> [String] {
        findings
            .filter { $0.score > 0 }
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map { "\($0.analyzerID) (\(Int($0.score.rounded())))" }
    }
}

/// One row of a batch report: either a completed analysis or a skipped
/// file, flattened into the fields the report formats actually display.
struct BatchReportEntry: Sendable {
    let filePath: String
    let score: Double?
    let verdict: String?
    let topContributors: [String]
    let skipReason: String?

    init(result: BatchAnalysisResult) {
        filePath = result.filePath
        switch result.outcome {
        case .analyzed(let report):
            score = report.overallScore
            verdict = report.verdict
            topContributors = report.topContributors()
            skipReason = nil
        case .skipped(let reason):
            score = nil
            verdict = nil
            topContributors = []
            skipReason = reason
        }
    }
}

/// The complete result of a `batch` scan: every file that was found,
/// sorted for display, plus the counts a summary line needs.
struct BatchReport: Sendable {
    let directory: String
    let entries: [BatchReportEntry]

    /// Builds a report from raw per-file results, sorting analyzed files by
    /// suspicion score descending -- the ordering `batch` promises -- ahead
    /// of skipped files (which have no score to sort by, so they're
    /// ordered alphabetically by path instead).
    init(directory: String, results: [BatchAnalysisResult]) {
        self.directory = directory
        let mapped = results.map(BatchReportEntry.init)
        let analyzed = mapped
            .filter { $0.skipReason == nil }
            .sorted { ($0.score ?? 0) > ($1.score ?? 0) }
        let skipped = mapped
            .filter { $0.skipReason != nil }
            .sorted { $0.filePath < $1.filePath }
        self.entries = analyzed + skipped
    }

    var analyzedCount: Int { entries.filter { $0.skipReason == nil }.count }
    var skippedCount: Int { entries.filter { $0.skipReason != nil }.count }
}
