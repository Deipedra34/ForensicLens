import XCTest
import ImageDecoding
@testable import ForensicLens
@testable import HTMLReporting

/// The "What this means" card and calibration table in HTML reports.
final class HTMLExplanationTests: XCTestCase {
    private let block = Region(x: 0, y: 0, width: 8, height: 8)

    private func explained(_ findings: [AnalyzerFinding], verbosity: NarrativeVerbosity = .full, narrative: Bool = true) -> ForensicReport {
        ReportExplainer(settings: .init(narrative: narrative, narrativeVerbosity: verbosity)).explain(SuspicionScorer().score(findings))
    }

    private func html(_ report: ForensicReport) throws -> String {
        let image = try Fixtures.imageData(from: Fixtures.noiseBuffer(width: 16, height: 16))
        return HTMLReportGenerator().render(report: report, image: image, sourcePath: "photo.ppm")
    }

    private func count(_ needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    func testExplainedReportShowsTheNarrativeAboveTheFindings() throws {
        let page = try html(explained([
            AnalyzerFinding(analyzerID: "prnu", score: 60, summary: "1 block.", indicators: [Indicator(message: "x", weight: 60, regions: [block])]),
            AnalyzerFinding(analyzerID: "cfa", score: 60, summary: "1 block.", indicators: [Indicator(message: "y", weight: 60, regions: [block])]),
        ]))
        let card = try XCTUnwrap(page.range(of: "<section class=\"card explanation\" id=\"explanation\">"))
        let findings = try XCTUnwrap(page.range(of: "<h2>Findings</h2>"))
        XCTAssertLessThan(card.lowerBound, findings.lowerBound)

        XCTAssertTrue(page.contains("What this means"))
        XCTAssertTrue(page.contains("id=\"calibrated-score\" data-score=\"76.6\""), "76.6 calibrated")
        XCTAssertTrue(page.contains("Key findings"))
        XCTAssertTrue(page.contains("Keep in mind"))
        XCTAssertTrue(page.contains("<summary>Check by check</summary>"))
        XCTAssertTrue(page.contains("<h2>Calibration</h2>"))
        XCTAssertTrue(page.contains("<tr data-analyzer=\"prnu\">"))
        XCTAssertTrue(page.contains("cfa + prnu agree at x 0-8, y 0-8"))
        XCTAssertEqual(count("<section", in: page), count("</section>", in: page))
    }

    func testBriefNarrativeHasNoWalkthrough() throws {
        let page = try html(explained([AnalyzerFinding(analyzerID: "clone", score: 80, summary: "Copied.", indicators: [])], verbosity: .brief))
        XCTAssertTrue(page.contains("What this means"))
        XCTAssertFalse(page.contains("Check by check"))
    }

    func testNarrativeOffKeepsTheCalibratedNumbersOnly() throws {
        let page = try html(explained([AnalyzerFinding(analyzerID: "clone", score: 80, summary: "Copied.", indicators: [])], narrative: false))
        XCTAssertTrue(page.contains("Calibrated confidence"))
        XCTAssertTrue(page.contains("<h2>Calibration</h2>"))
        XCTAssertFalse(page.contains("Key findings"))
    }

    func testUnexplainedReportHasNeitherSection() throws {
        let page = try html(SuspicionScorer().score([AnalyzerFinding(analyzerID: "clone", score: 80, summary: "Copied.", indicators: [])]))
        XCTAssertFalse(page.contains("What this means"))
        XCTAssertFalse(page.contains("<h2>Calibration</h2>"))
    }

    func testNarrativeTextIsHTMLEscaped() throws {
        // The metadata detail is quoted from the image's own EXIF.
        let page = try html(explained([
            AnalyzerFinding(analyzerID: "metadata", score: 40, summary: "Editing software.",
                            indicators: [Indicator(message: "Software tag reports \"<script>alert(1)</script>\".", weight: 40)]),
        ]))
        XCTAssertFalse(page.contains("<script>alert(1)</script>"))
        XCTAssertTrue(page.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
    }

    func testEngineReportsGetTheCardInTheCLIHTMLReport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("forensiclens-html-narrative-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = try Fixtures.pastingPatch(of: 24, from: (x: 8, y: 8), to: (x: 88, y: 88), into: Fixtures.noiseBuffer(width: 128, height: 128, seed: 42))
        let imagePath = root.appendingPathComponent("photo.ppm").path
        try Data(ImageEncoder.encodePPM(image)).write(to: URL(fileURLWithPath: imagePath))
        let htmlPath = root.appendingPathComponent("report.html").path

        let report = ForensicLensEngine(config: .default).run(on: try Fixtures.imageData(from: image), only: ["clone"])
        let page = HTMLReportGenerator().render(report: report, image: try Fixtures.imageData(from: image), sourcePath: imagePath)
        XCTAssertTrue(page.contains("copy-paste check"), "the clone finding is explained")
        try page.write(toFile: htmlPath, atomically: true, encoding: .utf8)
        XCTAssertTrue(FileManager.default.fileExists(atPath: htmlPath))
    }
}
