import XCTest
import BenchmarkReporting
@testable import forensiclens_readme_updater

/// Covers the README benchmark-table update logic behind
/// `scripts/benchmark/update-readme.sh` (Sources/forensiclens-readme-updater).
///
/// This is exactly the "unit test if practical" the update script's
/// `--input` flag is meant to enable: everything here runs against
/// in-memory strings and the checked-in sample fixture, with no real
/// benchmark run and no file left behind.
final class ReadmeUpdaterTests: XCTestCase {
    private let sampleResults = [
        BenchmarkResult(analyzer: "ELA", size: "64x64", pixels: 4096, milliseconds: 3.1),
        BenchmarkResult(analyzer: "Clone Detection", size: "64x64", pixels: 4096, milliseconds: 4.85)
    ]

    // MARK: - Table rendering

    func testRenderMarkdownTableIncludesHeaderAndOneRowPerResult() {
        let table = renderMarkdownTable(sampleResults)
        let lines = table.components(separatedBy: "\n")

        XCTAssertEqual(lines[0], "| Analyzer | Image size | Time (ms) |")
        XCTAssertEqual(lines[1], "| --- | --- | --- |")
        XCTAssertEqual(lines[2], "| ELA | 64x64 | 3.10 |")
        XCTAssertEqual(lines[3], "| Clone Detection | 64x64 | 4.85 |")
        XCTAssertEqual(lines.count, 4)
    }

    func testRenderMarkdownTableOnEmptyResultsIsJustTheHeader() {
        let table = renderMarkdownTable([])
        XCTAssertEqual(table, "| Analyzer | Image size | Time (ms) |\n| --- | --- | --- |")
    }

    // MARK: - Marker replacement

    private func makeReadme(body: String) -> String {
        """
        # ForensicLens

        Some intro text that must survive untouched.

        ## Benchmarking

        <!-- BENCHMARK-TABLE-START -->
        \(body)
        <!-- BENCHMARK-TABLE-END -->

        ## Testing

        Text after the markers that must also survive untouched.
        """
    }

    func testUpdateReplacesOnlyContentBetweenMarkers() throws {
        let source = makeReadme(body: "stale table content")
        let table = renderMarkdownTable(sampleResults)

        let updated = try updateReadmeContents(source, tableMarkdown: table)

        XCTAssertTrue(updated.contains("Some intro text that must survive untouched."))
        XCTAssertTrue(updated.contains("Text after the markers that must also survive untouched."))
        XCTAssertTrue(updated.contains(table))
        XCTAssertFalse(updated.contains("stale table content"))
        // Exactly one copy of each marker -- no duplication introduced.
        XCTAssertEqual(updated.components(separatedBy: "<!-- BENCHMARK-TABLE-START -->").count, 2)
        XCTAssertEqual(updated.components(separatedBy: "<!-- BENCHMARK-TABLE-END -->").count, 2)
    }

    func testUpdateIsIdempotentAcrossRepeatedRuns() throws {
        let source = makeReadme(body: "stale table content")
        let table = renderMarkdownTable(sampleResults)

        let once = try updateReadmeContents(source, tableMarkdown: table)
        let twice = try updateReadmeContents(once, tableMarkdown: table)

        XCTAssertEqual(once, twice)
    }

    func testUpdateThrowsWhenStartMarkerMissing() {
        let source = "no markers here\n<!-- BENCHMARK-TABLE-END -->"
        XCTAssertThrowsError(try updateReadmeContents(source, tableMarkdown: "table")) { error in
            XCTAssertEqual((error as? ReadmeUpdaterError)?.description.contains("BENCHMARK-TABLE-START"), true)
        }
    }

    func testUpdateThrowsWhenEndMarkerMissing() {
        let source = "<!-- BENCHMARK-TABLE-START -->\nno end marker here"
        XCTAssertThrowsError(try updateReadmeContents(source, tableMarkdown: "table")) { error in
            XCTAssertEqual((error as? ReadmeUpdaterError)?.description.contains("BENCHMARK-TABLE-END"), true)
        }
    }

    func testUpdateThrowsWhenAMarkerIsDuplicated() {
        let source = """
        <!-- BENCHMARK-TABLE-START -->
        old
        <!-- BENCHMARK-TABLE-END -->
        <!-- BENCHMARK-TABLE-START -->
        <!-- BENCHMARK-TABLE-END -->
        """
        XCTAssertThrowsError(try updateReadmeContents(source, tableMarkdown: "table"))
    }

    // MARK: - End-to-end against the checked-in sample fixture

    func testEndToEndAgainstSampleFixture() throws {
        let sampleURL = URL(fileURLWithPath: "scripts/benchmark/sample-benchmark.json")
        let data = try Data(contentsOf: sampleURL)
        let report = try JSONDecoder().decode(BenchmarkReport.self, from: data)

        XCTAssertFalse(report.results.isEmpty)

        let table = renderMarkdownTable(report.results)
        let source = makeReadme(body: "placeholder")
        let updated = try updateReadmeContents(source, tableMarkdown: table)

        XCTAssertTrue(updated.contains("| ELA | 64x64 | 3.10 |"))

        // Running the same report through a second time must be a no-op.
        let updatedAgain = try updateReadmeContents(updated, tableMarkdown: table)
        XCTAssertEqual(updated, updatedAgain)
    }
}
