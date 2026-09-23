import Foundation
import ForensicLens
import HTMLReporting
import ImageDecoding

/// What happened when `batch` tried to write one image's HTML report.
enum BatchHTMLReportOutcome: Sendable, Equatable {
    case written(fileName: String)
    case failed(reason: String)
}

/// Settings for `batch --html-report-dir`: where per-image HTML reports go,
/// which images qualify for one, and the file name each image's report
/// gets.
///
/// File names are all decided up front, from the complete sorted file
/// list, before any analysis starts. Deciding them inside the concurrent
/// analysis tasks instead would make two images that sanitize to the same
/// name (`a/b.jpg` and `a_b.jpg`) race for it, and which one got the `-2`
/// suffix would depend on which finished first.
struct BatchHTMLReportOptions: Sendable {
    /// Directory the reports and `index.html` are written to.
    let directory: String

    /// An image gets a report only if its overall score is strictly above
    /// this. The default of 0 means "any non-zero score".
    let threshold: Double

    /// Report file name (within `directory`) for each source image path.
    let fileNames: [String: String]

    static let indexFileName = "index.html"

    init(directory: String, threshold: Double, sourceRoot: String, files: [String]) {
        self.directory = directory
        self.threshold = threshold
        self.fileNames = Self.reportFileNames(for: files, sourceRoot: sourceRoot)
    }

    func shouldGenerate(for report: ForensicReport) -> Bool {
        report.overallScore > threshold
    }

    /// Renders and writes `report`'s HTML page for the image at
    /// `sourcePath`. Never throws: a failed write is returned as
    /// `.failed` so, like every other per-file problem in `batch`, it
    /// can't abort the rest of the run.
    func writeReport(_ report: ForensicReport, image: ImageData, sourcePath: String) -> BatchHTMLReportOutcome {
        guard let fileName = fileNames[sourcePath] else {
            return .failed(reason: "no report file name was planned for this image")
        }
        let html = HTMLReportGenerator().render(report: report, image: image, sourcePath: sourcePath)
        let outputPath = (directory as NSString).appendingPathComponent(fileName)
        do {
            try html.write(toFile: outputPath, atomically: true, encoding: .utf8)
            return .written(fileName: fileName)
        } catch {
            return .failed(reason: "could not write \(outputPath): \(error)")
        }
    }

    /// Writes `index.html`, linking every report that was successfully
    /// written, and returns its path.
    @discardableResult
    func writeIndex(for results: [BatchAnalysisResult], scannedDirectory: String) throws -> String {
        let entries = results.compactMap { result -> HTMLReportIndexEntry? in
            guard case .analyzed(let report) = result.outcome,
                  case .written(let fileName)? = result.htmlReport
            else { return nil }
            return HTMLReportIndexEntry(reportHref: fileName, sourcePath: result.filePath, score: report.overallScore, verdict: report.verdict)
        }
        let html = HTMLReportIndex.render(entries: entries, directory: scannedDirectory, threshold: threshold)
        let indexPath = (directory as NSString).appendingPathComponent(Self.indexFileName)
        try html.write(toFile: indexPath, atomically: true, encoding: .utf8)
        return indexPath
    }

    /// Maps each file to a flat, filesystem-safe report name derived from
    /// its path relative to `sourceRoot` (`nested/photo.jpg` ->
    /// `nested_photo.jpg.html`), adding a numeric suffix on collision.
    /// Collisions are checked case-insensitively, since the default
    /// filesystems on macOS and Windows are, and `index.html` is reserved.
    static func reportFileNames(for files: [String], sourceRoot: String) -> [String: String] {
        var used: Set<String> = [indexFileName]
        var names: [String: String] = [:]

        for file in files.sorted() {
            let base = sanitize(relativePath(of: file, under: sourceRoot))
            var candidate = "\(base).html"
            var suffix = 2
            while used.contains(candidate.lowercased()) {
                candidate = "\(base)-\(suffix).html"
                suffix += 1
            }
            used.insert(candidate.lowercased())
            names[file] = candidate
        }
        return names
    }

    private static func relativePath(of file: String, under root: String) -> String {
        guard !root.isEmpty, file.hasPrefix(root) else {
            return (file as NSString).lastPathComponent
        }
        let relative = file.dropFirst(root.count).drop(while: { $0 == "/" || $0 == "\\" })
        return relative.isEmpty ? (file as NSString).lastPathComponent : String(relative)
    }

    private static func sanitize(_ path: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
        let sanitized = String(path.map { allowed.contains($0) ? $0 : "_" })
        return sanitized.isEmpty ? "image" : sanitized
    }
}
