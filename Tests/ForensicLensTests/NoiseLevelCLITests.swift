import XCTest
import ImageDecoding
@testable import ForensicLens
@testable import forensiclens_cli
@testable import HTMLReporting

/// Covers the `noiselevel` CLI command and the analyzer's layer in the
/// HTML report.
final class NoiseLevelCLITests: XCTestCase {
    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("forensiclens-noise-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testNoiseLevelCommandRunsOnlyThatAnalyzerAndWritesAnHTMLReport() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let buffer = try Fixtures.noiseLevelImage(width: 320, height: 320, sigma: 3, splices: [
            (Region(x: 128, y: 64, width: 64, height: 64), .blurred(radius: 2)),
        ])
        let imagePath = root.appendingPathComponent("photo.ppm").path
        try Data(ImageEncoder.encodePPM(buffer)).write(to: URL(fileURLWithPath: imagePath))
        let htmlPath = root.appendingPathComponent("report.html").path

        let exitCode = await CLI.run(arguments: [
            "forensiclens-cli", "noiselevel", imagePath,
            "--json",
            "--html-report", htmlPath,
            "--config", root.appendingPathComponent("missing.yaml").path
        ])

        XCTAssertEqual(exitCode, 0)
        let html = try String(contentsOfFile: htmlPath, encoding: .utf8)
        XCTAssertTrue(html.contains("Noise-Level Consistency"))
        XCTAssertTrue(html.contains(HTMLReportGenerator.layerColors["noiselevel"] ?? "missing"))
        XCTAssertFalse(html.contains("Error Level Analysis"), "only the requested analyzer runs")
        XCTAssertFalse(html.contains("PRNU Sensor Noise Analysis"))
    }

    func testConfigFileCanTurnItOff() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let imagePath = root.appendingPathComponent("photo.ppm").path
        try Data(ImageEncoder.encodePPM(Fixtures.noiseLevelImage(width: 320, height: 320, sigma: 3))).write(to: URL(fileURLWithPath: imagePath))
        let configPath = root.appendingPathComponent("forensiclens.yaml").path
        try "noiseLevel:\n  enabled: false\n".write(toFile: configPath, atomically: true, encoding: .utf8)
        let htmlPath = root.appendingPathComponent("report.html").path

        let exitCode = await CLI.run(arguments: [
            "forensiclens-cli", "noiselevel", imagePath, "--html-report", htmlPath, "--config", configPath,
        ])
        XCTAssertEqual(exitCode, 0)
        let html = try String(contentsOfFile: htmlPath, encoding: .utf8)
        XCTAssertFalse(html.contains("Noise-Level Consistency"), "disabled analyzers don't run, even when named")
    }

    func testHTMLReportNamesTheAnalyzer() {
        XCTAssertEqual(HTMLReportGenerator.displayName(for: "noiselevel"), NoiseLevelAnalyzer().displayName)
        XCTAssertNotNil(HTMLReportGenerator.layerColors["noiselevel"])
        XCTAssertEqual(Set(HTMLReportGenerator.layerColors.values).count, HTMLReportGenerator.layerColors.count, "every layer has its own color")
    }
}
