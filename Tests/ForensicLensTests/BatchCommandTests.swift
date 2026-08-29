import XCTest
import ForensicLens
import ImageDecoding
@testable import forensiclens_cli

final class BatchCommandTests: XCTestCase {
    // MARK: - Directory walking

    func testRecursiveScanFindsTopLevelAndNestedFiles() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try write(Fixtures.uniformBuffer(width: 8, height: 8), to: root.appendingPathComponent("top.jpg"))
        let subdirectory = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)
        try write(Fixtures.uniformBuffer(width: 8, height: 8), to: subdirectory.appendingPathComponent("inner.png"))

        let recursiveFiles = try BatchFileScanner(extensions: ["jpg", "png"], recursive: true).scanFiles(in: root.path)
        XCTAssertEqual(recursiveFiles.count, 2)

        let topLevelOnly = try BatchFileScanner(extensions: ["jpg", "png"], recursive: false).scanFiles(in: root.path)
        XCTAssertEqual(topLevelOnly.count, 1)
        XCTAssertTrue(topLevelOnly[0].hasSuffix("top.jpg"))
    }

    func testExtensionFilteringOnlyMatchesConfiguredExtensions() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try write(Fixtures.uniformBuffer(width: 8, height: 8), to: root.appendingPathComponent("photo.png"))
        try write(Fixtures.uniformBuffer(width: 8, height: 8), to: root.appendingPathComponent("photo.gif"))

        let defaultExtensions = try BatchFileScanner(extensions: ["jpg", "jpeg", "png"], recursive: true).scanFiles(in: root.path)
        XCTAssertEqual(defaultExtensions.count, 1)
        XCTAssertTrue(defaultExtensions[0].hasSuffix("photo.png"))

        let customExtensions = try BatchFileScanner(extensions: ["png", "gif"], recursive: true).scanFiles(in: root.path)
        XCTAssertEqual(customExtensions.count, 2)
    }

    func testScanningAMissingDirectoryThrows() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertThrowsError(try BatchFileScanner(extensions: ["jpg"], recursive: true).scanFiles(in: missing.path)) { error in
            XCTAssertTrue(error is BatchScanError)
        }
    }

    // MARK: - Fault isolation

    func testCorruptFileIsSkippedWithReasonWhileRestOfBatchCompletes() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try write(Fixtures.uniformBuffer(width: 32, height: 32), to: root.appendingPathComponent("clean.jpg"))
        let cloneBase = try Fixtures.noiseBuffer(width: 128, height: 128, seed: 42)
        let cloneTrigger = try Fixtures.pastingPatch(of: 24, from: (x: 8, y: 8), to: (x: 90, y: 90), into: cloneBase)
        try write(cloneTrigger, to: root.appendingPathComponent("tampered.jpeg"))
        try Data([0x00, 0x01, 0x02, 0x03]).write(to: root.appendingPathComponent("corrupt.png"))

        let files = try BatchFileScanner(extensions: ["jpg", "jpeg", "png"], recursive: true).scanFiles(in: root.path)
        XCTAssertEqual(files.count, 3)

        let analyzer = BatchFileAnalyzer(engine: ForensicLensEngine(config: .default))
        // `onFileComplete` is documented to fire serially from `BatchRunner`'s
        // own task, never concurrently -- but its closure type is still
        // `@Sendable`, so a captured `var` trips the compiler's (overly
        // conservative here) Sendable-capture check. A reference-type box
        // sidesteps that without weakening the actual guarantee under test.
        let progress = ProgressBox()
        let results = await BatchRunner.run(files: files, analyzer: analyzer, maxConcurrency: 4) { _, completed, total in
            progress.completions.append((completed, total))
        }

        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(progress.completions.count, 3)
        XCTAssertEqual(progress.completions.last?.completed, 3)
        XCTAssertEqual(progress.completions.last?.total, 3)

        let report = BatchReport(directory: root.path, results: results)
        XCTAssertEqual(report.analyzedCount, 2)
        XCTAssertEqual(report.skippedCount, 1)

        let skippedEntry = try XCTUnwrap(report.entries.first { $0.filePath.hasSuffix("corrupt.png") })
        XCTAssertNotNil(skippedEntry.skipReason)
        XCTAssertNil(skippedEntry.score)

        let cloneEntry = try XCTUnwrap(report.entries.first { $0.filePath.hasSuffix("tampered.jpeg") })
        XCTAssertNil(cloneEntry.skipReason)
        XCTAssertGreaterThan(cloneEntry.score ?? 0, 0)
    }

    func testFullCLIBatchRunSkipsCorruptFileAndReportsTheRest() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try write(Fixtures.uniformBuffer(width: 16, height: 16), to: root.appendingPathComponent("clean.jpg"))
        try Data([0xDE, 0xAD, 0xBE, 0xEF]).write(to: root.appendingPathComponent("broken.jpg"))

        let outputPath = root.appendingPathComponent("report.json").path
        let exitCode = await CLI.run(arguments: [
            "forensiclens-cli", "batch", root.path,
            "--format", "json",
            "--output", outputPath,
            "--config", root.appendingPathComponent("does-not-exist.yaml").path
        ])

        XCTAssertEqual(exitCode, 0)
        let contents = try String(contentsOfFile: outputPath, encoding: .utf8)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contents.utf8)) as? [String: Any])
        XCTAssertEqual(json["analyzedCount"] as? Int, 1)
        XCTAssertEqual(json["skippedCount"] as? Int, 1)
    }

    // MARK: - Report formatting: JSON

    func testJSONFormatIsSortedByScoreDescendingWithSkippedFilesLast() throws {
        let results = makeMixedResults()
        let report = BatchReport(directory: "/tmp/photos", results: results)

        let rendered = try BatchReportFormatter.render(report, as: .json)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(rendered.utf8)) as? [String: Any])

        XCTAssertEqual(json["totalFiles"] as? Int, 4)
        XCTAssertEqual(json["analyzedCount"] as? Int, 3)
        XCTAssertEqual(json["skippedCount"] as? Int, 1)

        let entries = try XCTUnwrap(json["entries"] as? [[String: Any]])
        let filePaths = entries.map { $0["filePath"] as? String }
        XCTAssertEqual(filePaths, ["high.jpg", "medium.jpg", "low.jpg", "broken.jpg"])

        let scores = entries.compactMap { $0["score"] as? Double }
        XCTAssertEqual(scores, scores.sorted(by: >), "analyzed entries must be sorted by score descending")

        let brokenEntry = try XCTUnwrap(entries.first { $0["filePath"] as? String == "broken.jpg" })
        XCTAssertEqual(brokenEntry["status"] as? String, "skipped")
        XCTAssertEqual(brokenEntry["skipReason"] as? String, "could not read file")
        XCTAssertNil(brokenEntry["score"])

        let highEntry = try XCTUnwrap(entries.first { $0["filePath"] as? String == "high.jpg" })
        XCTAssertEqual(highEntry["status"] as? String, "analyzed")
        XCTAssertEqual(highEntry["topContributors"] as? [String], ["clone (90)"])
    }

    // MARK: - Report formatting: CSV

    func testCSVFormatIsSortedByScoreDescendingWithSkippedFilesLast() throws {
        let results = makeMixedResults()
        let report = BatchReport(directory: "/tmp/photos", results: results)

        let rendered = try BatchReportFormatter.render(report, as: .csv)
        let lines = rendered.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        XCTAssertEqual(lines.first, "file_path,status,score,verdict,top_contributors,skip_reason")
        XCTAssertEqual(lines.count, 5) // header + 4 rows

        let filePathColumn = lines.dropFirst().map { $0.split(separator: ",", maxSplits: 1)[0] }
        XCTAssertEqual(filePathColumn, ["high.jpg", "medium.jpg", "low.jpg", "broken.jpg"])

        XCTAssertTrue(lines[1].hasPrefix("high.jpg,analyzed,90,"))
        XCTAssertTrue(lines[4].hasPrefix("broken.jpg,skipped,,,"))
        XCTAssertTrue(lines[4].contains("could not read file"))
    }

    func testCSVEscapesFieldsContainingCommas() throws {
        let finding = AnalyzerFinding(analyzerID: "metadata", score: 12, summary: "s", indicators: [])
        let report = ForensicReport(overallScore: 12, verdict: "minor anomalies", findings: [finding])
        let result = BatchAnalysisResult(filePath: "weird, path.jpg", outcome: .analyzed(report))
        let batchReport = BatchReport(directory: "/tmp", results: [result])

        let rendered = try BatchReportFormatter.render(batchReport, as: .csv)
        XCTAssertTrue(rendered.contains("\"weird, path.jpg\""))
    }

    // MARK: - Test helpers

    /// A trivial reference-type accumulator for `BatchRunner`'s progress
    /// callback -- see the comment where it's used.
    private final class ProgressBox: @unchecked Sendable {
        var completions: [(completed: Int, total: Int)] = []
    }

    // MARK: - Fixtures

    /// Three analyzed results with distinct, hand-set scores plus one
    /// unreadable file -- built directly from `ForensicReport` values
    /// rather than run through real analyzers, so the expected ordering is
    /// exact and doesn't depend on any analyzer's internal thresholds.
    private func makeMixedResults() -> [BatchAnalysisResult] {
        let high = ForensicReport(
            overallScore: 90,
            verdict: "likely manipulated",
            findings: [AnalyzerFinding(analyzerID: "clone", score: 90, summary: "duplicated region found", indicators: [])]
        )
        let medium = ForensicReport(
            overallScore: 50,
            verdict: "suspicious",
            findings: [AnalyzerFinding(analyzerID: "ela", score: 50, summary: "elevated error levels", indicators: [])]
        )
        let low = ForensicReport(
            overallScore: 10,
            verdict: "likely authentic",
            findings: [AnalyzerFinding(analyzerID: "metadata", score: 10, summary: "minor anomaly", indicators: [])]
        )

        return [
            BatchAnalysisResult(filePath: "medium.jpg", outcome: .analyzed(medium)),
            BatchAnalysisResult(filePath: "broken.jpg", outcome: .skipped(reason: "could not read file")),
            BatchAnalysisResult(filePath: "high.jpg", outcome: .analyzed(high)),
            BatchAnalysisResult(filePath: "low.jpg", outcome: .analyzed(low))
        ]
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("forensiclens-batch-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ buffer: PixelBuffer, to url: URL) throws {
        try Data(ImageEncoder.encodePPM(buffer)).write(to: url)
    }
}
