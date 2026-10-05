/// The ground-truth label for one image in an evaluation dataset.
enum GroundTruth: String, Codable, Sendable, CaseIterable {
    case authentic
    case tampered
}

/// Binary-classification counts for "tampered" as the positive class.
///
/// This file is deliberately pure arithmetic: it knows nothing about file
/// paths, datasets, analyzers, or command-line flags. Everything that
/// computes a precision/recall/F1 number goes through here, which is what
/// lets `EvaluationMetricsTests` check it against hand-built confusion
/// matrices without a single image on disk.
struct ConfusionMatrix: Equatable, Codable, Sendable {
    /// Tampered images that were flagged.
    var truePositives: Int
    /// Authentic images that were flagged.
    var falsePositives: Int
    /// Authentic images that were left clean.
    var trueNegatives: Int
    /// Tampered images that were left clean.
    var falseNegatives: Int

    init(truePositives: Int = 0, falsePositives: Int = 0, trueNegatives: Int = 0, falseNegatives: Int = 0) {
        self.truePositives = truePositives
        self.falsePositives = falsePositives
        self.trueNegatives = trueNegatives
        self.falseNegatives = falseNegatives
    }

    /// Builds a matrix by classifying every `(label, score)` pair against
    /// `threshold` with `ThresholdClassifier.isFlagged`.
    init(scores: [(label: GroundTruth, score: Double)], threshold: Double) {
        self.init()
        for entry in scores {
            record(actual: entry.label, flagged: ThresholdClassifier.isFlagged(score: entry.score, threshold: threshold))
        }
    }

    /// Adds one classified image to the matching cell.
    mutating func record(actual: GroundTruth, flagged: Bool) {
        switch (actual, flagged) {
        case (.tampered, true): truePositives += 1
        case (.authentic, true): falsePositives += 1
        case (.authentic, false): trueNegatives += 1
        case (.tampered, false): falseNegatives += 1
        }
    }

    var total: Int {
        truePositives + falsePositives + trueNegatives + falseNegatives
    }

    // Every ratio below is defined as 0 when its denominator is 0 (e.g.
    // precision when nothing was flagged at all), rather than NaN. A NaN
    // would poison JSON output and make "which threshold maximizes F1"
    // comparisons meaningless, and 0 is the conventional reading in that
    // case anyway: no flags means no precision to speak of.

    /// TP / (TP + FP): of everything flagged, how much was really tampered.
    var precision: Double {
        Self.ratio(truePositives, truePositives + falsePositives)
    }

    /// TP / (TP + FN): of every tampered image, how many were flagged.
    var recall: Double {
        Self.ratio(truePositives, truePositives + falseNegatives)
    }

    /// The harmonic mean of precision and recall.
    var f1: Double {
        let p = precision
        let r = recall
        guard p + r > 0 else { return 0 }
        return 2 * p * r / (p + r)
    }

    /// (TP + TN) / total: the fraction of images classified correctly.
    var accuracy: Double {
        Self.ratio(truePositives + trueNegatives, total)
    }

    private static func ratio(_ numerator: Int, _ denominator: Int) -> Double {
        guard denominator > 0 else { return 0 }
        return Double(numerator) / Double(denominator)
    }
}

/// The single decision rule that turns a 0...100 suspicion score into
/// "flagged" or "clean". Kept in one place so the single-threshold run and
/// every point of a sweep classify images identically.
enum ThresholdClassifier {
    /// An image is flagged when its score meets or exceeds `threshold`.
    static func isFlagged(score: Double, threshold: Double) -> Bool {
        score >= threshold
    }
}

/// Precision, recall, F1, and accuracy at one threshold, alongside the
/// confusion matrix they were derived from. The derived metrics are stored
/// (not just computed) so they appear in JSON output.
struct ThresholdMetrics: Equatable, Codable, Sendable {
    let threshold: Double
    let confusionMatrix: ConfusionMatrix
    let precision: Double
    let recall: Double
    let f1: Double
    let accuracy: Double

    init(threshold: Double, confusionMatrix: ConfusionMatrix) {
        self.threshold = threshold
        self.confusionMatrix = confusionMatrix
        self.precision = confusionMatrix.precision
        self.recall = confusionMatrix.recall
        self.f1 = confusionMatrix.f1
        self.accuracy = confusionMatrix.accuracy
    }

    init(scores: [(label: GroundTruth, score: Double)], threshold: Double) {
        self.init(threshold: threshold, confusionMatrix: ConfusionMatrix(scores: scores, threshold: threshold))
    }
}

/// Errors from building a threshold range for `--sweep`.
enum ThresholdSweepError: Error, Equatable, CustomStringConvertible {
    case invalidRange(min: Double, max: Double, step: Double)

    var description: String {
        switch self {
        case .invalidRange(let min, let max, let step):
            return "invalid sweep range (min \(min), max \(max), step \(step)): need 0 <= min <= max <= 100 and step > 0."
        }
    }
}

/// Evaluates the same set of scores across many thresholds.
enum ThresholdSweep {
    /// Every threshold from `min` to `max` (inclusive) in increments of
    /// `step`. Each value is computed as `min + i * step` rather than by
    /// repeated addition, so floating-point drift can't skip the endpoint.
    static func thresholds(min: Double, max: Double, step: Double) throws -> [Double] {
        guard min.isFinite, max.isFinite, step.isFinite, step > 0, min >= 0, max <= 100, min <= max else {
            throw ThresholdSweepError.invalidRange(min: min, max: max, step: step)
        }
        let count = Int(((max - min) / step + 1e-9).rounded(.down)) + 1
        // Rounded to 6 decimal places so a step like 0.1 prints as 0.3,
        // not 0.30000000000000004, in tables and CSV output.
        return (0..<count).map { index in
            ((min + Double(index) * step) * 1e6).rounded() / 1e6
        }
    }

    static func evaluate(_ scores: [(label: GroundTruth, score: Double)], at thresholds: [Double]) -> [ThresholdMetrics] {
        thresholds.map { ThresholdMetrics(scores: scores, threshold: $0) }
    }

    /// The point with the highest F1. Ties go to the higher accuracy, then
    /// to the lower threshold, so the answer is deterministic.
    static func best(of points: [ThresholdMetrics]) -> ThresholdMetrics? {
        points.min { lhs, rhs in
            if lhs.f1 != rhs.f1 { return lhs.f1 > rhs.f1 }
            if lhs.accuracy != rhs.accuracy { return lhs.accuracy > rhs.accuracy }
            return lhs.threshold < rhs.threshold
        }
    }
}
