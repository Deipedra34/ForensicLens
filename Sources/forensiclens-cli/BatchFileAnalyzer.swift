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

    /// Set only when `batch --html-report-dir` is on and this image scored
    /// above the report threshold.
    var htmlReport: BatchHTMLReportOutcome? = nil
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

    /// The same `--tile-size` / `--no-tiling` debug override the
    /// single-image commands accept, applied to every file in the batch --
    /// tiling is transparent to `batch` exactly as it is to `report`/`ela`/
    /// etc., with no separate code path for it.
    var tiling: TilingOverride = .none

    /// When set (`--html-report-dir`), each qualifying image's HTML report
    /// is written right here, while its decoded `ImageData` is still in
    /// hand -- so a large batch never has to keep every image in memory
    /// until the end of the run just to render reports afterwards.
    var htmlReports: BatchHTMLReportOptions? = nil

    func analyze(filePath: String) -> BatchAnalysisResult {
        guard let data = FileManager.default.contents(atPath: filePath) else {
            return BatchAnalysisResult(filePath: filePath, outcome: .skipped(reason: "could not read file"))
        }
        do {
            let image = try ImageData.load([UInt8](data))
            let report = engine.run(on: image, tiling: tiling)
            var result = BatchAnalysisResult(filePath: filePath, outcome: .analyzed(report))
            if let htmlReports, htmlReports.shouldGenerate(for: report) {
                result.htmlReport = htmlReports.writeReport(report, image: image, sourcePath: filePath)
            }
            return result
        } catch {
            return BatchAnalysisResult(filePath: filePath, outcome: .skipped(reason: "\(error)"))
        }
    }
}
