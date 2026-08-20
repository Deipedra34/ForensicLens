import XCTest
import ForensicLens

final class ScoringTests: XCTestCase {
    func testEmptyFindingsProduceZeroScore() {
        let report = SuspicionScorer().score([])

        XCTAssertEqual(report.overallScore, 0)
        XCTAssertEqual(report.verdict, "likely authentic")
        XCTAssertTrue(report.findings.isEmpty)
    }

    func testSingleStrongFindingDominatesTheScore() {
        let strong = AnalyzerFinding(analyzerID: "clone", score: 90, summary: "strong match", indicators: [])

        let report = SuspicionScorer().score([strong])

        XCTAssertEqual(report.overallScore, 90)
        XCTAssertEqual(report.verdict, "likely manipulated")
    }

    func testCorroboratingFindingsNudgeScoreUpWithoutSimpleAveraging() {
        let strong = AnalyzerFinding(analyzerID: "clone", score: 80, summary: "strong match", indicators: [])
        let weak = AnalyzerFinding(analyzerID: "metadata", score: 20, summary: "minor anomaly", indicators: [])

        let report = SuspicionScorer().score([strong, weak])

        // The combined score should sit above the dominant finding alone
        // (corroboration matters) but nowhere near a plain average, which
        // would pull a strong finding down just because another analyzer
        // found comparatively little.
        XCTAssertGreaterThan(report.overallScore, 80)
        let average = (80.0 + 20.0) / 2
        XCTAssertGreaterThan(report.overallScore, average)
    }

    func testScoreNeverExceeds100() {
        let a = AnalyzerFinding(analyzerID: "ela", score: 100, summary: "a", indicators: [])
        let b = AnalyzerFinding(analyzerID: "metadata", score: 100, summary: "b", indicators: [])
        let c = AnalyzerFinding(analyzerID: "clone", score: 100, summary: "c", indicators: [])

        let report = SuspicionScorer().score([a, b, c])

        XCTAssertEqual(report.overallScore, 100)
    }

    func testVerdictThresholds() {
        XCTAssertEqual(SuspicionScorer().score([finding(10)]).verdict, "likely authentic")
        XCTAssertEqual(SuspicionScorer().score([finding(30)]).verdict, "minor anomalies")
        XCTAssertEqual(SuspicionScorer().score([finding(55)]).verdict, "suspicious")
        XCTAssertEqual(SuspicionScorer().score([finding(85)]).verdict, "likely manipulated")
    }

    func testTextReportIncludesEveryFindingAndIndicator() {
        let finding = AnalyzerFinding(
            analyzerID: "ela",
            score: 42,
            summary: "example summary",
            indicators: [Indicator(message: "example indicator", weight: 10)]
        )
        let report = SuspicionScorer().score([finding])

        XCTAssertTrue(report.textReport.contains("example summary"))
        XCTAssertTrue(report.textReport.contains("example indicator"))
        XCTAssertTrue(report.textReport.contains("ela"))
    }

    func testFindingScoreIsClampedToValidRange() {
        let tooHigh = AnalyzerFinding(analyzerID: "ela", score: 250, summary: "s", indicators: [])
        let tooLow = AnalyzerFinding(analyzerID: "ela", score: -50, summary: "s", indicators: [])

        XCTAssertEqual(tooHigh.score, 100)
        XCTAssertEqual(tooLow.score, 0)
    }

    private func finding(_ score: Double) -> AnalyzerFinding {
        AnalyzerFinding(analyzerID: "ela", score: score, summary: "s", indicators: [])
    }
}
