import Foundation
import ForensicLens
import ImageDecoding

/// The outcome of running the analysis pipeline against one file on disk:
/// either a full `ForensicReport`, or a reason it couldn't be produced.
struct BatchAnalysisResult: Sendable {
    enum Outcome: Sendable {
        case analyzed(ForensicReport)
        case skipped(reason: String)
    }

    let filePath: String
    let outcome: Outcome
}

/// Runs the existing `ForensicLensEngine` pipeline -- the same one the
/// single-image CLI commands use -- against one file on disk.
///
/// This is the fault-isolation seam for the `batch` command: an unreadable
/// file, bytes that don't decode as a known image format, or any other
/// per-file failure becomes a `BatchAnalysisResult.skipped` value here
/// instead of throwing, so `BatchRunner` can treat every file uniformly and
/// one bad file never aborts the batch.
struct BatchFileAnalyzer: Sendable {
    let engine: ForensicLensEngine

    func analyze(filePath: String) -> BatchAnalysisResult {
        guard let data = FileManager.default.contents(atPath: filePath) else {
            return BatchAnalysisResult(filePath: filePath, outcome: .skipped(reason: "could not read file"))
        }
        do {
            let image = try ImageData.load([UInt8](data))
            let report = engine.run(on: image)
            return BatchAnalysisResult(filePath: filePath, outcome: .analyzed(report))
        } catch {
            return BatchAnalysisResult(filePath: filePath, outcome: .skipped(reason: "\(error)"))
        }
    }
}
