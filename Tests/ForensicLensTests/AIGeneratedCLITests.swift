import XCTest
import ImageDecoding
@testable import ForensicLens
@testable import forensiclens_cli
@testable import HTMLReporting

/// Covers the `aigenerated` CLI command and the analyzer's layer in the
/// HTML report.
final class AIGeneratedCLITests: XCTestCase {
    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("forensiclens-aigen-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testAIGeneratedCommandRunsOnlyThatAnalyzerAndWritesAnHTMLReport() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let imagePath = root.appendingPathComponent("render.bmp").path
        try Data(ImageEncoder.encodeBMP(Fixtures.likelyGeneratedImage())).write(to: URL(fileURLWithPath: imagePath))
        let htmlPath = root.appendingPathComponent("report.html").path

        let exitCode = await CLI.run(arguments: [
            "forensiclens-cli", "aigenerated", imagePath,
            "--json",
            "--html-report", htmlPath,
            "--config", root.appendingPathComponent("missing.yaml").path
        ])

        XCTAssertEqual(exitCode, 0)
        let html = try String(contentsOfFile: htmlPath, encoding: .utf8)
        XCTAssertTrue(html.contains("AI-Generated Image Signals"))
        XCTAssertTrue(html.contains(HTMLReportGenerator.layerColors["aigenerated"] ?? "missing"))
        XCTAssertFalse(html.contains("Error Level Analysis"), "only the requested analyzer runs")
    }

    func testHTMLReportNamesTheAnalyzer() {
        XCTAssertEqual(HTMLReportGenerator.displayName(for: "aigenerated"), AIGeneratedImageAnalyzer().displayName)
        XCTAssertNotNil(HTMLReportGenerator.layerColors["aigenerated"])
    }
}
