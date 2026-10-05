import Foundation

/// Per-class image counts for the images that were actually analyzed.
struct DatasetCounts: Equatable, Codable, Sendable {
    let authentic: Int
    let tampered: Int
    let skipped: Int

    init(authentic: Int, tampered: Int, skipped: Int) {
        self.authentic = authentic
        self.tampered = tampered
        self.skipped = skipped
    }

    init(run: EvaluationRun) {
        self.init(
            authentic: run.samples.filter { $0.label == .authentic }.count,
            tampered: run.samples.filter { $0.label == .tampered }.count,
            skipped: run.skipped.count
        )
    }
}

/// The result of a single-threshold evaluation (`--threshold`).
struct EvaluationReport: Equatable, Codable, Sendable {
    let dataset: String
    let counts: DatasetCounts
    let result: ThresholdMetrics
    let samples: [ScoredSample]
    let skipped: [SkippedSample]

    init(dataset: String, run: EvaluationRun, threshold: Double) {
        self.dataset = dataset
        self.counts = DatasetCounts(run: run)
        self.result = ThresholdMetrics(scores: run.scores, threshold: threshold)
        self.samples = run.samples
        self.skipped = run.skipped
    }
}

/// The result of a threshold sweep (`--sweep`).
struct SweepReport: Equatable, Codable, Sendable {
    let dataset: String
    let counts: DatasetCounts
    let points: [ThresholdMetrics]
    /// The threshold that maximizes F1; see `ThresholdSweep.best(of:)`.
    let best: ThresholdMetrics?
    let samples: [ScoredSample]
    let skipped: [SkippedSample]

    init(dataset: String, run: EvaluationRun, thresholds: [Double]) {
        self.dataset = dataset
        self.counts = DatasetCounts(run: run)
        self.points = ThresholdSweep.evaluate(run.scores, at: thresholds)
        self.best = ThresholdSweep.best(of: points)
        self.samples = run.samples
        self.skipped = run.skipped
    }
}

/// Renders evaluation reports as terminal text, JSON, or CSV.
enum EvaluationReportFormatter {
    static func text(_ report: EvaluationReport) -> String {
        var lines = header(dataset: report.dataset, counts: report.counts)
        lines.append("Threshold: flagged when suspicion score >= \(format(report.result.threshold))")
        lines.append("")
        lines.append(contentsOf: confusionMatrixLines(report.result.confusionMatrix))
        lines.append("")
        lines.append(contentsOf: metricLines(report.result))
        return lines.joined(separator: "\n")
    }

    static func text(_ report: SweepReport) -> String {
        var lines = header(dataset: report.dataset, counts: report.counts)
        lines.append(row(["Threshold", "Precision", "Recall", "F1", "Accuracy", "TP", "FP", "TN", "FN"]))
        lines.append(row(Array(repeating: "---------", count: 9)))
        for point in report.points {
            let m = point.confusionMatrix
            lines.append(row([
                format(point.threshold), percent(point.precision), percent(point.recall), percent(point.f1), percent(point.accuracy),
                "\(m.truePositives)", "\(m.falsePositives)", "\(m.trueNegatives)", "\(m.falseNegatives)"
            ]))
        }
        lines.append("")
        if let best = report.best {
            lines.append("Best threshold by F1: \(format(best.threshold)) (F1 \(percent(best.f1)), precision \(percent(best.precision)), recall \(percent(best.recall)), accuracy \(percent(best.accuracy)))")
            lines.append("")
            lines.append(contentsOf: confusionMatrixLines(best.confusionMatrix))
        } else {
            lines.append("No thresholds evaluated.")
        }
        return lines.joined(separator: "\n")
    }

    /// One row per sweep threshold, for plotting precision/recall curves.
    static func csv(_ report: SweepReport) -> String {
        var lines = ["threshold,precision,recall,f1,accuracy,true_positives,false_positives,true_negatives,false_negatives"]
        for point in report.points {
            let m = point.confusionMatrix
            lines.append([
                format(point.threshold), decimal(point.precision), decimal(point.recall), decimal(point.f1), decimal(point.accuracy),
                "\(m.truePositives)", "\(m.falsePositives)", "\(m.trueNegatives)", "\(m.falseNegatives)"
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func json<T: Encodable>(_ report: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(report), as: UTF8.self)
    }

    // MARK: - Helpers

    private static func header(dataset: String, counts: DatasetCounts) -> [String] {
        [
            "ForensicLens Evaluation",
            "=======================",
            "Dataset: \(dataset)",
            "Analyzed: \(counts.authentic + counts.tampered) images (\(counts.authentic) authentic, \(counts.tampered) tampered), \(counts.skipped) skipped",
            ""
        ]
    }

    private static func confusionMatrixLines(_ m: ConfusionMatrix) -> [String] {
        [
            "Confusion matrix      Predicted tampered   Predicted clean",
            "  Actual tampered     \(pad("TP \(m.truePositives)", 21))FN \(m.falseNegatives)",
            "  Actual authentic    \(pad("FP \(m.falsePositives)", 21))TN \(m.trueNegatives)"
        ]
    }

    private static func metricLines(_ metrics: ThresholdMetrics) -> [String] {
        [
            "Precision: \(percent(metrics.precision))",
            "Recall:    \(percent(metrics.recall))",
            "F1 score:  \(percent(metrics.f1))",
            "Accuracy:  \(percent(metrics.accuracy))"
        ]
    }

    private static func row(_ cells: [String]) -> String {
        cells.map { pad($0, 10) }.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }

    /// Thresholds print without a trailing ".0" when they're whole numbers.
    private static func format(_ threshold: Double) -> String {
        threshold == threshold.rounded() ? String(Int(threshold)) : String(threshold)
    }

    private static func percent(_ value: Double) -> String {
        String(format: "%.1f%%", value * 100)
    }

    private static func decimal(_ value: Double) -> String {
        String(format: "%.4f", value)
    }
}
