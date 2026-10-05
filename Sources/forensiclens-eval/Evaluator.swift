import BatchProcessing

/// One dataset image the pipeline analyzed, with its ground truth and the
/// combined suspicion score `ForensicLensEngine` gave it.
struct ScoredSample: Equatable, Codable, Sendable {
    let path: String
    let label: GroundTruth
    let score: Double
}

/// One dataset image that couldn't be analyzed (unreadable, undecodable,
/// ...), and why. Skipped images are excluded from every metric.
struct SkippedSample: Equatable, Codable, Sendable {
    let path: String
    let label: GroundTruth
    let reason: String
}

/// Everything one pass over a dataset produced. Scores are computed once
/// and then classified at as many thresholds as needed, so `--sweep`
/// costs no more analysis time than a single `--threshold` run.
struct EvaluationRun: Sendable {
    let samples: [ScoredSample]
    let skipped: [SkippedSample]

    var scores: [(label: GroundTruth, score: Double)] {
        samples.map { ($0.label, $0.score) }
    }
}

/// Runs the full analysis pipeline over a labeled dataset.
///
/// This adds no analysis logic of its own: each file goes through
/// `BatchFileAnalyzer` -- the same `ForensicLensEngine` + `SuspicionScorer`
/// path, and the same skip-don't-abort fault isolation, that
/// `forensiclens-cli batch` uses -- and this type only pairs the resulting
/// score back up with the file's label.
enum Evaluator {
    static func run(
        dataset: [LabeledImage],
        analyzer: BatchFileAnalyzer,
        maxConcurrency: Int,
        onFileComplete: (@Sendable (BatchAnalysisResult, _ completed: Int, _ total: Int) -> Void)? = nil
    ) async -> EvaluationRun {
        var labels: [String: GroundTruth] = [:]
        for image in dataset {
            labels[image.path] = image.label
        }

        let results = await BatchRunner.run(
            files: dataset.map(\.path),
            analyzer: analyzer,
            maxConcurrency: maxConcurrency,
            onFileComplete: onFileComplete
        )

        var samples: [ScoredSample] = []
        var skipped: [SkippedSample] = []
        for result in results {
            guard let label = labels[result.filePath] else { continue }
            switch result.outcome {
            case .analyzed(let report):
                samples.append(ScoredSample(path: result.filePath, label: label, score: report.overallScore))
            case .skipped(let reason):
                skipped.append(SkippedSample(path: result.filePath, label: label, reason: reason))
            }
        }

        // BatchRunner returns results in completion order; sort so reports
        // are byte-for-byte reproducible between runs.
        return EvaluationRun(
            samples: samples.sorted { $0.path < $1.path },
            skipped: skipped.sorted { $0.path < $1.path }
        )
    }
}
