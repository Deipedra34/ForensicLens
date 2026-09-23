import XCTest
import ForensicLens
import HTMLReporting
import ImageDecoding
@testable import forensiclens_cli

final class HTMLReportTests: XCTestCase {
    // MARK: - Embedded image

    func testPPMImageIsEmbeddedAsBMPDataURI() throws {
        let image = try Fixtures.imageData(from: Fixtures.noiseBuffer(width: 16, height: 16))
        let html = HTMLReportGenerator().render(report: SuspicionScorer().score([]), image: image, sourcePath: "photo.ppm")

        // Browsers can't display PPM, so it's converted to BMP from the
        // already-decoded pixels.
        XCTAssertTrue(html.contains("<img id=\"analyzed-image\" src=\"data:image/bmp;base64,"))
        XCTAssertTrue(html.contains("width=\"16\" height=\"16\""))
    }

    func testBMPImageEmbedsOriginalBytesWithoutReencoding() throws {
        let bmpBytes = ImageEncoder.encodeBMP(try Fixtures.noiseBuffer(width: 8, height: 8))
        let image = try ImageData.load(bmpBytes)

        let embedded = try XCTUnwrap(EmbeddedImage.from(image))
        XCTAssertEqual(embedded.bytes, bmpBytes)
        XCTAssertEqual(embedded.dataURI, "data:image/bmp;base64,\(Data(bmpBytes).base64EncodedString())")

        let html = HTMLReportGenerator().render(report: SuspicionScorer().score([]), image: image, sourcePath: "photo.bmp")
        XCTAssertTrue(html.contains(embedded.dataURI))
    }

    func testUndecodableJPEGStillEmbedsOriginalBytesWithoutOverlay() throws {
        let image = try ImageData.load(Fixtures.jpegBytesWithNoExif())
        XCTAssertNil(image.pixels)

        let html = HTMLReportGenerator().render(report: SuspicionScorer().score([]), image: image, sourcePath: "photo.jpg")
        XCTAssertTrue(html.contains("src=\"data:image/jpeg;base64,"))
        XCTAssertFalse(html.contains("<svg"))
    }

    // MARK: - Overlays, legend, score

    func testOneOverlayPerDistinctRegionWithOriginalCoordinates() throws {
        let html = try renderSampleReport()

        XCTAssertEqual(occurrences(of: "class=\"overlay\"", in: html), 5)
        XCTAssertEqual(occurrences(of: "data-analyzer=\"ela\" x=", in: html), 2, "ELA's summary and per-cell indicators share regions; each should be drawn once")
        XCTAssertEqual(occurrences(of: "data-analyzer=\"clone\" x=", in: html), 2)
        XCTAssertEqual(occurrences(of: "data-analyzer=\"doublecompression\" x=", in: html), 1)

        XCTAssertTrue(html.contains("<rect class=\"overlay\" data-analyzer=\"ela\" x=\"16\" y=\"32\" width=\"16\" height=\"16\">"))
        XCTAssertTrue(html.contains("<rect class=\"overlay\" data-analyzer=\"ela\" x=\"48\" y=\"0\" width=\"16\" height=\"8\">"))
        XCTAssertTrue(html.contains("<rect class=\"overlay\" data-analyzer=\"clone\" x=\"8\" y=\"8\" width=\"16\" height=\"16\">"))
        XCTAssertTrue(html.contains("<rect class=\"overlay\" data-analyzer=\"clone\" x=\"40\" y=\"40\" width=\"16\" height=\"16\">"))
        XCTAssertTrue(html.contains("<rect class=\"overlay\" data-analyzer=\"doublecompression\" x=\"2\" y=\"4\" width=\"56\" height=\"56\">"))

        // The overlay coordinate space is the image's own pixel grid.
        XCTAssertTrue(html.contains("viewBox=\"0 0 64 64\""))
    }

    func testLegendAndTogglesListEachActiveSpatialAnalyzer() throws {
        let html = try renderSampleReport()

        for (id, name) in [("ela", ELAAnalyzer().displayName), ("clone", CloneDetectionAnalyzer().displayName), ("doublecompression", DoubleCompressionAnalyzer().displayName)] {
            XCTAssertTrue(html.contains("<li class=\"legend-entry\" data-analyzer=\"\(id)\">"), "missing legend entry for \(id)")
            XCTAssertTrue(html.contains("<input type=\"checkbox\" checked data-layer=\"\(id)\">"), "missing toggle for \(id)")
            XCTAssertTrue(html.contains("<g class=\"layer\" data-layer=\"\(id)\""), "missing overlay layer for \(id)")
            XCTAssertTrue(html.contains(HTMLTestEscape.escape(name)))
        }

        // Metadata has no spatial regions, so no layer or legend entry --
        // but it still appears in the breakdown.
        XCTAssertFalse(html.contains("legend-entry\" data-analyzer=\"metadata\""))
        XCTAssertFalse(html.contains("data-layer=\"metadata\""))
        XCTAssertTrue(html.contains("<section class=\"card finding\" data-analyzer=\"metadata\">"))

        // Distinct color per analyzer.
        XCTAssertTrue(html.contains("fill=\"#f76707\""))
        XCTAssertTrue(html.contains("fill=\"#1c7ed6\""))
        XCTAssertTrue(html.contains("fill=\"#ae3ec9\""))

        // Toggle behavior is plain inline JavaScript, no external scripts.
        XCTAssertTrue(html.contains("<script>"))
        XCTAssertFalse(html.contains("<script src"))
    }

    func testOverallScoreIsShownRoundedLikeTheTextReport() throws {
        let html = try renderSampleReport()
        XCTAssertTrue(html.contains("data-score=\"73\""))
        XCTAssertTrue(html.contains("<span class=\"score-value\">73</span>"))
        XCTAssertTrue(html.contains("likely manipulated"))
    }

    func testBreakdownListsAnalyzerDescriptionsAndRegionCoordinates() throws {
        let html = try renderSampleReport()
        XCTAssertTrue(html.contains("2 region(s) show error levels inconsistent"))
        XCTAssertTrue(html.contains("Block at (8,8) closely matches block at (40,40)"))
        XCTAssertTrue(html.contains("<li class=\"region\">x 16, y 32, 16\u{00D7}16 px</li>"))
        XCTAssertTrue(html.contains("<li class=\"region\">x 2, y 4, 56\u{00D7}56 px</li>"))
        XCTAssertTrue(html.contains("No EXIF metadata"))
    }

    func testEmbeddedTextIsHTMLEscaped() throws {
        let finding = AnalyzerFinding(
            analyzerID: "ela",
            score: 30,
            summary: "<script>alert(\"x\")</script> & 'quoted'",
            indicators: [Indicator(message: "a < b > c", weight: 10, regions: [Region(x: 0, y: 0, width: 8, height: 8)])]
        )
        let image = try Fixtures.imageData(from: Fixtures.noiseBuffer(width: 16, height: 16))
        let html = HTMLReportGenerator().render(report: SuspicionScorer().score([finding]), image: image, sourcePath: "dir/<evil>&\"name\".ppm")

        XCTAssertFalse(html.contains("<script>alert"))
        XCTAssertTrue(html.contains("&lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt; &amp; &#39;quoted&#39;"))
        XCTAssertTrue(html.contains("a &lt; b &gt; c"))
        XCTAssertTrue(html.contains("dir/&lt;evil&gt;&amp;&quot;name&quot;.ppm"))
        XCTAssertFalse(html.contains("<evil>"))
    }

    // MARK: - Zero findings

    func testReportWithNoFindingsIsValidAndSaysNoAnomaliesDetected() throws {
        let image = try Fixtures.imageData(from: Fixtures.uniformBuffer(width: 32, height: 32))
        let html = HTMLReportGenerator().render(report: SuspicionScorer().score([]), image: image, sourcePath: "clean.ppm")

        XCTAssertTrue(html.hasPrefix("<!DOCTYPE html>"))
        XCTAssertTrue(html.contains("</html>"))
        XCTAssertEqual(occurrences(of: "<section", in: html), occurrences(of: "</section>", in: html))
        XCTAssertTrue(html.contains("No anomalies detected"))
        XCTAssertTrue(html.contains("data-score=\"0\""))
        XCTAssertEqual(occurrences(of: "class=\"overlay\"", in: html), 0)
        XCTAssertTrue(html.contains("data:image/bmp;base64,"))
    }

    func testCleanImageRunThroughEveryAnalyzerSaysNoAnomaliesDetected() throws {
        let image = try Fixtures.imageData(from: Fixtures.uniformBuffer(width: 32, height: 32))
        let report = ForensicLensEngine(config: .default).run(on: image)
        XCTAssertEqual(report.overallScore, 0)

        let html = HTMLReportGenerator().render(report: report, image: image, sourcePath: "clean.ppm")
        XCTAssertTrue(html.contains("<p class=\"no-anomalies\">No anomalies detected.</p>"))
        XCTAssertEqual(occurrences(of: "class=\"overlay\"", in: html), 0)
        // Spatial analyzers that ran still get a legend entry, with no regions.
        XCTAssertTrue(html.contains("<li class=\"legend-entry\" data-analyzer=\"ela\">"))
        XCTAssertTrue(html.contains("(0 regions)"))
    }

    // MARK: - Analyzer regions

    func testELAExposesTheFlaggedCellAsARegion() throws {
        let base = try Fixtures.uniformBuffer(width: 64, height: 64, value: 100)
        let withPatch = try Fixtures.stampingNoisePatch(of: 16, at: (x: 16, y: 16), into: base)
        let image = try Fixtures.imageData(from: withPatch)
        var config = ForensicLensConfig.default
        config.ela.errorThreshold = 2.0
        config.ela.flaggedRegionFraction = 0.01

        let finding = try ELAAnalyzer().analyze(image, config: config)
        let regions = finding.indicators.flatMap(\.regions)
        XCTAssertTrue(regions.contains(Region(x: 16, y: 16, width: 16, height: 16)))

        let html = HTMLReportGenerator().render(report: SuspicionScorer().score([finding]), image: image, sourcePath: "patch.ppm")
        XCTAssertTrue(html.contains("<rect class=\"overlay\" data-analyzer=\"ela\" x=\"16\" y=\"16\" width=\"16\" height=\"16\">"))
        XCTAssertEqual(occurrences(of: "class=\"overlay\"", in: html), Set(regions).count)
    }

    func testCloneDetectionExposesSourceAndCopyBlocksAsRegions() throws {
        let base = try Fixtures.noiseBuffer(width: 128, height: 128, seed: 42)
        let withClone = try Fixtures.pastingPatch(of: 24, from: (x: 8, y: 8), to: (x: 88, y: 88), into: base)
        let image = try Fixtures.imageData(from: withClone)
        let config = ForensicLensConfig.default
        let blockSize = max(4, config.cloneDetection.blockSize)

        let finding = try CloneDetectionAnalyzer().analyze(image, config: config)
        let regions = finding.indicators.flatMap(\.regions)
        XCTAssertTrue(regions.contains(Region(x: 8, y: 8, width: blockSize, height: blockSize)))
        XCTAssertTrue(regions.contains(Region(x: 88, y: 88, width: blockSize, height: blockSize)))

        // Every per-match indicator carries exactly its two blocks.
        for indicator in finding.indicators.dropFirst() {
            XCTAssertEqual(indicator.regions.count, 2)
        }
    }

    func testTiledELARegionsAreTranslatedIntoImageCoordinates() throws {
        let base = try Fixtures.uniformBuffer(width: 64, height: 64, value: 100)
        let withPatch = try Fixtures.stampingNoisePatch(of: 16, at: (x: 32, y: 32), into: base)
        let image = try Fixtures.imageData(from: withPatch)
        var config = ForensicLensConfig.default
        config.ela.errorThreshold = 2.0
        config.ela.flaggedRegionFraction = 0.01

        let report = ForensicLensEngine(config: config).run(on: image, only: ["ela"], tiling: TilingOverride(forcedTileSize: 32))
        let regions = try XCTUnwrap(report.findings.first).indicators.flatMap(\.regions)

        XCTAssertFalse(regions.isEmpty)
        let bounds = Region(x: 0, y: 0, width: 64, height: 64)
        for region in regions {
            XCTAssertEqual(region.intersection(bounds), region, "\(region) falls outside the image")
        }
        let patch = Region(x: 32, y: 32, width: 16, height: 16)
        XCTAssertTrue(regions.contains { $0.intersection(patch) != nil }, "no tiled region covers the stamped patch")
    }

    func testIndicatorJSONOmitsEmptyRegionsAndDecodesLegacyJSON() throws {
        let plain = try JSONEncoder().encode(Indicator(message: "m", weight: 1))
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("regions"))

        let legacy = try JSONDecoder().decode(Indicator.self, from: Data(#"{"message":"m","weight":1}"#.utf8))
        XCTAssertEqual(legacy.regions, [])

        let located = Indicator(message: "m", weight: 1, regions: [Region(x: 1, y: 2, width: 3, height: 4)])
        let roundTripped = try JSONDecoder().decode(Indicator.self, from: JSONEncoder().encode(located))
        XCTAssertEqual(roundTripped, located)
    }

    // MARK: - CLI: single image

    func testCLIHTMLReportFlagWritesSelfContainedReport() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let imagePath = root.appendingPathComponent("photo.ppm").path
        try Data(ImageEncoder.encodePPM(Fixtures.noiseBuffer(width: 32, height: 32))).write(to: URL(fileURLWithPath: imagePath))
        let htmlPath = root.appendingPathComponent("report.html").path

        let exitCode = await CLI.run(arguments: [
            "forensiclens-cli", "report", imagePath,
            "--html-report", htmlPath,
            "--config", root.appendingPathComponent("does-not-exist.yaml").path
        ])

        XCTAssertEqual(exitCode, 0)
        let html = try String(contentsOfFile: htmlPath, encoding: .utf8)
        XCTAssertTrue(html.contains("data:image/bmp;base64,"))
        XCTAssertFalse(html.contains("src=\"http"))
        XCTAssertFalse(html.contains("href=\"http"))
    }

    func testCLIHTMLReportFlagWithoutPathFails() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let imagePath = root.appendingPathComponent("photo.ppm").path
        try Data(ImageEncoder.encodePPM(Fixtures.uniformBuffer(width: 8, height: 8))).write(to: URL(fileURLWithPath: imagePath))

        let exitCode = await CLI.run(arguments: ["forensiclens-cli", "report", imagePath, "--html-report"])
        XCTAssertEqual(exitCode, 1)
    }

    // MARK: - Batch: index.html and threshold filtering

    func testBatchWritesReportsOnlyAboveThresholdAndAnIndexLinkingThem() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let images = try makeBatchImages(in: root)
        let reportDir = root.appendingPathComponent("reports").path
        try FileManager.default.createDirectory(atPath: reportDir, withIntermediateDirectories: true)

        let options = BatchHTMLReportOptions(directory: reportDir, threshold: 0, sourceRoot: images.directory, files: images.files)
        let analyzer = BatchFileAnalyzer(engine: ForensicLensEngine(config: .default), htmlReports: options)
        let results = await BatchRunner.run(files: images.files, analyzer: analyzer, maxConcurrency: 2)
        try options.writeIndex(for: results, scannedDirectory: images.directory)

        let clean = try XCTUnwrap(results.first { $0.filePath.hasSuffix("clean.ppm") })
        let tampered = try XCTUnwrap(results.first { $0.filePath.hasSuffix("tampered.ppm") })
        guard case .analyzed(let cleanReport) = clean.outcome, case .analyzed(let tamperedReport) = tampered.outcome else {
            return XCTFail("both images should have been analyzed")
        }
        XCTAssertEqual(cleanReport.overallScore, 0)
        XCTAssertGreaterThan(tamperedReport.overallScore, 0)

        XCTAssertNil(clean.htmlReport, "a zero-score image must not get a report at the default threshold")
        XCTAssertEqual(tampered.htmlReport, .written(fileName: "tampered.ppm.html"))

        let written = try FileManager.default.contentsOfDirectory(atPath: reportDir).sorted()
        XCTAssertEqual(written, ["index.html", "tampered.ppm.html"])

        let index = try String(contentsOfFile: (reportDir as NSString).appendingPathComponent("index.html"), encoding: .utf8)
        XCTAssertTrue(index.contains("href=\"tampered.ppm.html\""))
        XCTAssertFalse(index.contains("clean.ppm"))
        XCTAssertEqual(occurrences(of: "class=\"report-row\"", in: index), 1)
        XCTAssertTrue(index.contains(">\(Int(tamperedReport.overallScore.rounded()))/100<"))
    }

    func testBatchThresholdAboveEveryScoreProducesEmptyIndex() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let images = try makeBatchImages(in: root)
        let reportDir = root.appendingPathComponent("reports").path

        let exitCode = await CLI.run(arguments: [
            "forensiclens-cli", "batch", images.directory,
            "--extensions", "ppm",
            "--output", root.appendingPathComponent("summary.txt").path,
            "--html-report-dir", reportDir,
            "--html-report-threshold", "100",
            "--config", root.appendingPathComponent("does-not-exist.yaml").path
        ])
        XCTAssertEqual(exitCode, 0)

        let written = try FileManager.default.contentsOfDirectory(atPath: reportDir)
        XCTAssertEqual(written, ["index.html"])
        let index = try String(contentsOfFile: (reportDir as NSString).appendingPathComponent("index.html"), encoding: .utf8)
        XCTAssertTrue(index.contains("No images scored above the threshold"))
        XCTAssertEqual(occurrences(of: "class=\"report-row\"", in: index), 0)
    }

    func testIndexIsSortedByScoreDescending() {
        let entries = [
            HTMLReportIndexEntry(reportHref: "low.html", sourcePath: "low.jpg", score: 10, verdict: "likely authentic"),
            HTMLReportIndexEntry(reportHref: "high.html", sourcePath: "high.jpg", score: 90, verdict: "likely manipulated"),
            HTMLReportIndexEntry(reportHref: "mid.html", sourcePath: "mid.jpg", score: 50, verdict: "suspicious"),
        ]
        let html = HTMLReportIndex.render(entries: entries, directory: "photos", threshold: 0)

        let positions = ["high.html", "mid.html", "low.html"].map { href -> Int in
            guard let range = html.range(of: "href=\"\(href)\"") else {
                XCTFail("\(href) missing from index")
                return -1
            }
            return html.distance(from: html.startIndex, to: range.lowerBound)
        }
        XCTAssertEqual(positions, positions.sorted())
        XCTAssertEqual(occurrences(of: "class=\"report-row\"", in: html), 3)
    }

    func testReportFileNamesAreFlatAndUnique() {
        let names = BatchHTMLReportOptions.reportFileNames(
            for: ["/photos/a/b.jpg", "/photos/a_b.jpg", "/photos/A_B.jpg", "/photos/index"],
            sourceRoot: "/photos"
        )
        XCTAssertEqual(Set(names.values).count, 4)
        XCTAssertEqual(names["/photos/A_B.jpg"], "A_B.jpg.html")
        XCTAssertEqual(names["/photos/a/b.jpg"], "a_b.jpg-2.html")
        XCTAssertEqual(names["/photos/a_b.jpg"], "a_b.jpg-3.html")
        XCTAssertEqual(names["/photos/index"], "index-2.html")
        XCTAssertFalse(names.values.contains("index.html"))
    }

    func testThresholdWithoutReportDirectoryIsRejected() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let images = try makeBatchImages(in: root)

        let exitCode = await CLI.run(arguments: ["forensiclens-cli", "batch", images.directory, "--html-report-threshold", "10"])
        XCTAssertEqual(exitCode, 1)
    }

    // MARK: - Helpers

    /// A hand-built report with known regions, so overlay counts and
    /// coordinates can be asserted exactly rather than depending on any
    /// analyzer's thresholds.
    private func renderSampleReport() throws -> String {
        let cellA = Region(x: 16, y: 32, width: 16, height: 16)
        let cellB = Region(x: 48, y: 0, width: 16, height: 8)
        let ela = AnalyzerFinding(analyzerID: "ela", score: 55, summary: "2 region(s) show error levels inconsistent with a single uniform compression history.", indicators: [
            Indicator(message: "2 regions flagged.", weight: 30, regions: [cellA, cellB]),
            Indicator(message: "Region A flagged.", weight: 20, regions: [cellA]),
            Indicator(message: "Region B flagged.", weight: 20, regions: [cellB]),
        ])
        let clone = AnalyzerFinding(analyzerID: "clone", score: 60, summary: "1 duplicated region pair(s) found.", indicators: [
            Indicator(message: "Block at (8,8) closely matches block at (40,40).", weight: 20, regions: [
                Region(x: 8, y: 8, width: 16, height: 16),
                Region(x: 40, y: 40, width: 16, height: 16),
            ]),
        ])
        let doubleCompression = AnalyzerFinding(analyzerID: "doublecompression", score: 20, summary: "Periodic DCT coefficient pattern detected.", indicators: [
            Indicator(message: "Periodic pattern.", weight: 20, regions: [Region(x: 2, y: 4, width: 56, height: 56)]),
        ])
        let metadata = AnalyzerFinding(analyzerID: "metadata", score: 20, summary: "No EXIF metadata found in a JPEG file.", indicators: [
            Indicator(message: "No Exif APP1 segment was found.", weight: 20),
        ])

        // Built directly (not via SuspicionScorer) so the score is exact.
        let report = ForensicReport(overallScore: 72.6, verdict: "likely manipulated", findings: [ela, metadata, clone, doubleCompression])
        let image = try Fixtures.imageData(from: Fixtures.noiseBuffer(width: 64, height: 64))
        return HTMLReportGenerator().render(report: report, image: image, sourcePath: "sample.ppm")
    }

    private func makeBatchImages(in root: URL) throws -> (directory: String, files: [String]) {
        let directory = root.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        try Data(ImageEncoder.encodePPM(Fixtures.uniformBuffer(width: 32, height: 32))).write(to: directory.appendingPathComponent("clean.ppm"))
        let base = try Fixtures.noiseBuffer(width: 128, height: 128, seed: 42)
        let tampered = try Fixtures.pastingPatch(of: 24, from: (x: 8, y: 8), to: (x: 88, y: 88), into: base)
        try Data(ImageEncoder.encodePPM(tampered)).write(to: directory.appendingPathComponent("tampered.ppm"))

        let files = try BatchFileScanner(extensions: ["ppm"], recursive: true).scanFiles(in: directory.path)
        return (directory.path, files)
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("forensiclens-html-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// Mirrors the report's escaping for the handful of assertions that need
/// to look up an analyzer display name exactly as it appears in the HTML
/// (e.g. "EXIF / Metadata Analysis" is unchanged, but a name with `&` or
/// quotes wouldn't be).
private enum HTMLTestEscape {
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
