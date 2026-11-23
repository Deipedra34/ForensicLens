import XCTest
@testable import ForensicLens

/// How the calibrated confidence and narrative show up in the text report
/// and in JSON, with the narrative on, off, and absent.
final class ReportOutputTests: XCTestCase {
    private let block = Region(x: 128, y: 64, width: 64, height: 64)

    private var findings: [AnalyzerFinding] {
        [
            .clean(analyzerID: "ela", summary: "No cross-quality-consistent error-level anomalies detected."),
            AnalyzerFinding(analyzerID: "prnu", score: 60, summary: "1 block with inconsistent sensor noise.",
                            indicators: [Indicator(message: "Block has almost no sensor noise.", weight: 60, regions: [block])]),
            AnalyzerFinding(analyzerID: "cfa", score: 60, summary: "1 block without the demosaicing pattern.",
                            indicators: [Indicator(message: "Block is missing the CFA trace.", weight: 60, regions: [block])]),
        ]
    }

    private func report(narrative: Bool = true, verbosity: NarrativeVerbosity = .brief) -> ForensicReport {
        ReportExplainer(settings: .init(narrative: narrative, narrativeVerbosity: verbosity))
            .explain(SuspicionScorer().score(findings), imageSize: ImageSize(width: 256, height: 256))
    }

    // MARK: - Text

    func testTextReportLeadsWithTheNarrativeAndKeepsTheRawDetailsBelow() throws {
        let text = report().textReport
        let narrative = try XCTUnwrap(text.range(of: "What this means"))
        let details = try XCTUnwrap(text.range(of: "Technical details"))
        XCTAssertLessThan(narrative.lowerBound, details.lowerBound)

        XCTAssertTrue(text.contains("Overall suspicion score:"), text)
        XCTAssertTrue(text.contains("Calibrated confidence: 76.6/100"), text)
        XCTAssertTrue(text.contains("3 of 3 checks could examine this image"), text)
        XCTAssertTrue(text.contains("Key findings:"), text)
        XCTAssertTrue(text.contains("Keep in mind:"), text)
        XCTAssertFalse(text.contains("Check by check:"), "brief has no walkthrough")

        // The raw per-detector lines, as before, after the narrative.
        let rawLine = try XCTUnwrap(text.range(of: "[prnu] score 60/100 -- 1 block with inconsistent sensor noise."))
        XCTAssertGreaterThan(rawLine.lowerBound, details.lowerBound)
        XCTAssertTrue(text.contains("  - Block has almost no sensor noise."), text)

        // And the calibration arithmetic.
        XCTAssertTrue(text.contains("Calibration (raw score -> normalized strength x reliability = evidence):"), text)
        XCTAssertTrue(text.contains("0.60 x 0.80 = 0.48"), text)
        XCTAssertTrue(text.contains("-> no evidence (found nothing)"), "the clean ELA line: \(text)")
        XCTAssertFalse(text.contains("-> not counted"), "every detector here could judge the image")
        XCTAssertTrue(text.contains("Agreement: cfa + prnu at x 128-192, y 64-128"), text)
        XCTAssertTrue(text.contains("Combined: 1 - product(1 - evidence) = 76.6/100"), text)
    }

    func testFullTextReportIncludesTheWalkthrough() {
        let text = report(verbosity: .full).textReport
        XCTAssertTrue(text.contains("Check by check:"), text)
        XCTAssertTrue(text.contains("nothing unusual found"), text)
    }

    func testTextReportWithTheNarrativeOffKeepsTheCalibratedNumbers() {
        let explained = report(narrative: false)
        XCTAssertNil(explained.explanation)
        XCTAssertNotNil(explained.confidence)
        let text = explained.textReport
        XCTAssertFalse(text.contains("What this means"), text)
        XCTAssertTrue(text.contains("Calibrated confidence: 76.6/100"), text)
        XCTAssertTrue(text.contains("Technical details"), text)
        XCTAssertTrue(text.contains("Combined: 1 - product(1 - evidence)"), text)
    }

    func testUnexplainedReportRendersExactlyAsBefore() {
        let plain = SuspicionScorer().score(findings)
        XCTAssertEqual(plain.textReport, """
        ForensicLens Report
        ====================
        Overall suspicion score: 69/100 (suspicious)

        [ela] score 0/100 -- No cross-quality-consistent error-level anomalies detected.
        [prnu] score 60/100 -- 1 block with inconsistent sensor noise.
          - Block has almost no sensor noise.
        [cfa] score 60/100 -- 1 block without the demosaicing pattern.
          - Block is missing the CFA trace.
        """)
    }

    func testNotCountedDetectorsAreMarkedInTheCalibrationLines() {
        let withNotApplicable = findings + [.clean(analyzerID: "jpegghost", summary: "HEIF/HEIC images are compressed with HEVC; JPEG Ghost Detection is not applicable.")]
        let text = ReportExplainer().explain(SuspicionScorer().score(withNotApplicable)).textReport
        XCTAssertTrue(text.contains("notApplicable"), text)
        XCTAssertTrue(text.contains("-> not counted"), text)
    }

    // MARK: - JSON

    private func json(_ report: ForensicReport) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(report)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testJSONCarriesTheConfidenceAndTheStructuredExplanation() throws {
        let object = try json(report(verbosity: .full))
        XCTAssertNotNil(object["overallScore"])
        XCTAssertNotNil(object["findings"])

        let confidence = try XCTUnwrap(object["confidence"] as? [String: Any])
        XCTAssertEqual(confidence["score"] as? Double, 76.6)
        XCTAssertEqual(confidence["verdict"] as? String, "likely manipulated")
        XCTAssertEqual(confidence["assessedDetectors"] as? Int, 3)
        XCTAssertEqual((confidence["contributions"] as? [Any])?.count, 3)
        let agreement = try XCTUnwrap((confidence["agreements"] as? [[String: Any]])?.first)
        XCTAssertEqual(agreement["analyzerIDs"] as? [String], ["cfa", "prnu"])
        XCTAssertEqual(agreement["applied"] as? Bool, true)

        let explanation = try XCTUnwrap(object["explanation"] as? [String: Any])
        XCTAssertEqual(explanation["verbosity"] as? String, "full")
        XCTAssertNotNil(explanation["headline"] as? String)
        XCTAssertNotNil(explanation["summary"] as? String)
        XCTAssertFalse((explanation["keyFindings"] as? [Any])?.isEmpty ?? true)
        XCTAssertFalse((explanation["caveats"] as? [Any])?.isEmpty ?? true)
        XCTAssertEqual((explanation["walkthrough"] as? [Any])?.count, 3)
        let appendix = try XCTUnwrap(explanation["technicalAppendix"] as? [[String: Any]])
        XCTAssertEqual(appendix.compactMap { $0["analyzerID"] as? String }, ["ela", "prnu", "cfa"])
        XCTAssertEqual(appendix[1]["status"] as? String, "flagged")
        XCTAssertEqual(appendix[0]["status"] as? String, "clean")
    }

    func testJSONOmitsTheExplanationWhenTheNarrativeIsOff() throws {
        let object = try json(report(narrative: false))
        XCTAssertNil(object["explanation"])
        XCTAssertNotNil(object["confidence"])
    }

    func testJSONRoundTripsAndOlderJSONStillDecodes() throws {
        let explained = report(verbosity: .full)
        let decoded = try JSONDecoder().decode(ForensicReport.self, from: JSONEncoder().encode(explained))
        XCTAssertEqual(decoded, explained)

        // A report written before these fields existed.
        let old = #"{"overallScore": 12, "verdict": "likely authentic", "findings": []}"#
        let legacy = try JSONDecoder().decode(ForensicReport.self, from: Data(old.utf8))
        XCTAssertNil(legacy.confidence)
        XCTAssertNil(legacy.explanation)
        XCTAssertEqual(legacy.overallScore, 12)
    }
}
