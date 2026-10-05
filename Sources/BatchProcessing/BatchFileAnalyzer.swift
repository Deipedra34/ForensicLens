import Foundation
import ForensicLens
import ImageDecoding

/// The outcome of running the analysis pipeline against one file on disk:
/// either a full `ForensicReport`, or a reason it couldn't be produced.
public struct BatchAnalysisResult: Sendable {
    public enum Outcome: Sendable {
        case analyzed(ForensicReport)
        case skipped(reason: String)
    }

    public let filePath: String
    public let outcome: Outcome

    /// Set only when `batch --html-report-dir` is on and this image scored
    /// above the report threshold.
    public var htmlReport: BatchHTMLReportOutcome?

    public init(filePath: String, outcome: Outcome, htmlReport: BatchHTMLReportOutcome? = nil) {
        self.filePath = filePath
        self.outcome = outcome
        self.htmlReport = htmlReport
    }
}

/// Runs the existing `ForensicLensEngine` pipeline -- the same one the
/// single-image CLI commands use -- against one file on disk.
///
/// This is the fault-isolation seam for the `batch` command: an unreadable
/// file, bytes that don't decode as a known image format, or any other
/// per-file failure becomes a `BatchAnalysisResult.skipped` value here
/// instead of throwing, so `BatchRunner` can treat every file uniformly and
/// one bad file never aborts the batch. `forensiclens-eval` reuses this
/// same seam, so a corrupt image in an evaluation dataset is skipped exactly
/// the way it would be in `batch`.
public struct BatchFileAnalyzer: Sendable {
    public let engine: ForensicLensEngine

    /// The same `--tile-size` / `--no-tiling` debug override the
    /// single-image commands accept, applied to every file in the batch --
    /// tiling is transparent to `batch` exactly as it is to `report`/`ela`/
    /// etc., with no separate code path for it.
    public var tiling: TilingOverride

    /// When set (`--html-report-dir`), each qualifying image's HTML report
    /// is written right here, while its decoded `ImageData` is still in
    /// hand -- so a large batch never has to keep every image in memory
    /// until the end of the run just to render reports afterwards.
    public var htmlReports: BatchHTMLReportOptions?

    public init(engine: ForensicLensEngine, tiling: TilingOverride = .none, htmlReports: BatchHTMLReportOptions? = nil) {
        self.engine = engine
        self.tiling = tiling
        self.htmlReports = htmlReports
    }

    public func analyze(filePath: String) -> BatchAnalysisResult {
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
