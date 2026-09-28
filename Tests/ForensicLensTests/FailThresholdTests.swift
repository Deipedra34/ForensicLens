import XCTest
import ForensicLens
import ImageDecoding
@testable import forensiclens_cli

/// Covers `batch --fail-threshold`, and `batch` taking explicit file paths
/// rather than a single directory -- the two CLI changes the GitHub Action
/// and the pre-commit hook are built on.
final class FailThresholdTests: XCTestCase {
    // MARK: - Exit status

    func testBatchExitsNonZeroWhenAnImageMeetsTheThreshold() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let tampered = try writeTamperedImage(in: root)
        let score = try analyzedScore(of: tampered)
        XCTAssertGreaterThan(score, 0, "the fixture needs a non-zero score for this test to mean anything")

        // Exactly at the image's own score: "meets or exceeds" must fail.
        let exitCode = await runBatch(root.path, failThreshold: score, in: root)
        XCTAssertEqual(exitCode, CLI.failThresholdExitCode)
        XCTAssertNotEqual(exitCode, 0)
    }

    func testBatchExitsZeroWhenEveryImageIsBelowTheThreshold() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let tampered = try writeTamperedImage(in: root)
        let score = try analyzedScore(of: tampered)
        try XCTSkipIf(score >= 100, "fixture already scores the maximum; nothing is above it")

        let exitCode = await runBatch(root.path, failThreshold: min(100, score + 0.5), in: root)
        XCTAssertEqual(exitCode, 0)
    }

    func testBatchStillWritesItsReportBeforeFailing() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try writeTamperedImage(in: root)

        let outputPath = root.appendingPathComponent("report.json").path
        let exitCode = await CLI.run(arguments: [
            "forensiclens-cli", "batch", root.path,
            "--format", "json",
            "--output", outputPath,
            "--fail-threshold", "0",
            "--config", root.appendingPathComponent("does-not-exist.yaml").path
        ])

        XCTAssertEqual(exitCode, CLI.failThresholdExitCode)
        let contents = try String(contentsOfFile: outputPath, encoding: .utf8)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contents.utf8)) as? [String: Any])
        XCTAssertEqual(json["analyzedCount"] as? Int, 1)
    }

    func testSkippedFilesNeverTripTheThreshold() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([0xDE, 0xAD, 0xBE, 0xEF]).write(to: root.appendingPathComponent("broken.jpg"))

        // A threshold of 0 fails on any analyzed image at all, so the only
        // way this exits 0 is if the unreadable file isn't counted.
        let exitCode = await runBatch(root.path, failThreshold: 0, in: root)
        XCTAssertEqual(exitCode, 0)
    }

    // MARK: - Flag parsing

    func testFailThresholdIsOffUnlessGiven() throws {
        XCTAssertNil(try CLI.parseFailThreshold(parsed(options: [:])))
        XCTAssertEqual(try CLI.parseFailThreshold(parsed(options: ["--fail-threshold": "70"])), 70)
        XCTAssertEqual(try CLI.parseFailThreshold(parsed(options: ["--fail-threshold": "45.5"])), 45.5)
    }

    func testInvalidFailThresholdValuesAreRejected() {
        for raw in ["abc", "-1", "101", "nan", ""] {
            XCTAssertThrowsError(try CLI.parseFailThreshold(parsed(options: ["--fail-threshold": raw])), "\"\(raw)\" should be rejected")
        }
        XCTAssertThrowsError(try CLI.parseFailThreshold(parsed(flags: ["--fail-threshold"])))
    }

    func testInvalidFailThresholdFailsTheRunWithStatusOne() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(Fixtures.uniformBuffer(width: 16, height: 16), to: root.appendingPathComponent("clean.jpg"))

        let exitCode = await CLI.run(arguments: ["forensiclens-cli", "batch", root.path, "--fail-threshold", "high"])
        XCTAssertEqual(exitCode, 1)
    }

    func testEntriesScoringAtLeastIncludesTheBoundaryAndExcludesSkippedFiles() {
        func analyzed(_ path: String, score: Double) -> BatchAnalysisResult {
            BatchAnalysisResult(filePath: path, outcome: .analyzed(ForensicReport(overallScore: score, verdict: "v", findings: [])))
        }
        let results = [
            analyzed("above.jpg", score: 80),
            analyzed("exact.jpg", score: 70),
            analyzed("below.jpg", score: 69.9),
            BatchAnalysisResult(filePath: "broken.jpg", outcome: .skipped(reason: "could not read file"))
        ]

        let failing = BatchReport(directory: "/tmp", results: results).entries(scoringAtLeast: 70)
        XCTAssertEqual(failing.map(\.filePath), ["above.jpg", "exact.jpg"])
    }

    // MARK: - Explicit file lists

    func testScannerAcceptsAMixOfFilesAndDirectories() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let subdirectory = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)

        let single = root.appendingPathComponent("single.jpg")
        try write(Fixtures.uniformBuffer(width: 8, height: 8), to: single)
        try write(Fixtures.uniformBuffer(width: 8, height: 8), to: subdirectory.appendingPathComponent("a.png"))
        let ignored = root.appendingPathComponent("notes.txt")
        try Data("not an image".utf8).write(to: ignored)

        let scanner = BatchFileScanner(extensions: ["jpg", "png"], recursive: true)
        let files = try scanner.scanFiles(in: [single.path, subdirectory.path, ignored.path, single.path])
        XCTAssertEqual(files.count, 2, "duplicates and non-matching extensions are dropped")
        XCTAssertTrue(files.contains(single.path))

        XCTAssertThrowsError(try scanner.scanFiles(in: [root.appendingPathComponent("missing.jpg").path])) { error in
            XCTAssertTrue(error is BatchScanError)
        }
    }

    func testBatchRunOverExplicitFilesOnlyAnalyzesThoseFiles() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first.jpg")
        let second = root.appendingPathComponent("second.jpg")
        try write(Fixtures.uniformBuffer(width: 16, height: 16), to: first)
        try write(Fixtures.uniformBuffer(width: 16, height: 16), to: second)
        try write(Fixtures.uniformBuffer(width: 16, height: 16), to: root.appendingPathComponent("unlisted.jpg"))

        let outputPath = root.appendingPathComponent("report.json").path
        let exitCode = await CLI.run(arguments: [
            "forensiclens-cli", "batch", first.path, second.path,
            "--format", "json",
            "--output", outputPath,
            "--config", root.appendingPathComponent("does-not-exist.yaml").path
        ])

        XCTAssertEqual(exitCode, 0)
        let contents = try String(contentsOfFile: outputPath, encoding: .utf8)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contents.utf8)) as? [String: Any])
        XCTAssertEqual(json["totalFiles"] as? Int, 2)
    }

    // MARK: - Helpers

    private func runBatch(_ path: String, failThreshold: Double, in root: URL) async -> Int32 {
        await CLI.run(arguments: [
            "forensiclens-cli", "batch", path,
            "--fail-threshold", String(failThreshold),
            "--output", root.appendingPathComponent("report.txt").path,
            "--config", root.appendingPathComponent("does-not-exist.yaml").path
        ])
    }

    /// The same synthetic copy-move forgery `CloneDetectionAnalyzerTests`
    /// uses (destination on the 8px block grid), known to score above zero.
    private func writeTamperedImage(in root: URL) throws -> URL {
        let base = try Fixtures.noiseBuffer(width: 128, height: 128, seed: 42)
        let tampered = try Fixtures.pastingPatch(of: 24, from: (x: 8, y: 8), to: (x: 88, y: 88), into: base)
        let url = root.appendingPathComponent("tampered.jpeg")
        try write(tampered, to: url)
        return url
    }

    /// Scores `url` through the same analyzer `batch` uses, so the
    /// threshold tests are pinned to the image's actual score rather than
    /// to a hard-coded number that would break if an analyzer is retuned.
    private func analyzedScore(of url: URL) throws -> Double {
        let result = BatchFileAnalyzer(engine: ForensicLensEngine(config: .default)).analyze(filePath: url.path)
        guard case .analyzed(let report) = result.outcome else {
            XCTFail("fixture image was skipped")
            return 0
        }
        return report.overallScore
    }

    private func parsed(flags: Set<String> = [], options: [String: String] = [:]) -> CLI.ParsedArguments {
        CLI.ParsedArguments(positionals: [], flags: flags, options: options)
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("forensiclens-fail-threshold-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ buffer: PixelBuffer, to url: URL) throws {
        try Data(ImageEncoder.encodePPM(buffer)).write(to: url)
    }
}
