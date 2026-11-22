import XCTest
import ImageDecoding
@testable import ForensicLens

/// The narrative when some detectors don't apply, can't judge the image, or
/// fail: they must be explained as such -- never as clean results or as
/// evidence -- and a result with nothing assessable must read as
/// inconclusive.
final class NotApplicableNarrativeTests: XCTestCase {
    private func explain(_ findings: [AnalyzerFinding], _ verbosity: NarrativeVerbosity = .full) -> ReportExplanation {
        NarrativeGenerator(verbosity: verbosity).explain(findings: findings, confidence: ConfidenceCalibrator().calibrate(findings))
    }

    /// What the engine reports for a HEIC with a copy-move clone: the three
    /// JPEG-specific checks don't apply, the rest ran.
    private func heicFindings() throws -> [AnalyzerFinding] {
        let image = ImageData(rawBytes: [], pixels: try Fixtures.noiseBuffer(width: 64, height: 64, seed: 1), format: .heif)
        let analyzers: [any Analyzer] = [ELAAnalyzer(), JPEGGhostAnalyzer(), DoubleCompressionAnalyzer()]
        let jpegSpecific = try analyzers.map { try $0.analyze(image, config: .default) }
        return jpegSpecific + [
            AnalyzerFinding(analyzerID: "clone", score: 85, summary: "1 duplicated region.",
                            indicators: [Indicator(message: "Copied block.", weight: 85, regions: [Region(x: 0, y: 0, width: 16, height: 16), Region(x: 40, y: 40, width: 16, height: 16)])]),
            .clean(analyzerID: "metadata", summary: "EXIF metadata present and internally consistent; no anomalies found."),
        ]
    }

    func testNotApplicableChecksAreExplainedAsNotApplying() throws {
        let findings = try heicFindings()
        let explanation = explain(findings)

        // Not key findings: they found nothing and judged nothing.
        XCTAssertEqual(explanation.keyFindings.flatMap(\.analyzerIDs), ["clone"])

        // A caveat accounts for all three, as not applying to this kind of image.
        let caveat = try XCTUnwrap(explanation.caveats.first { $0.hasPrefix("Not every check") }, "\(explanation.caveats)")
        XCTAssertTrue(caveat.contains("3 don't apply"), caveat)
        XCTAssertTrue(caveat.contains("neither for nor against"), caveat)

        // The walkthrough says so for each, with the detector's own reason.
        for id in ["ela", "jpegghost", "doublecompression"] {
            let entry = try XCTUnwrap(explanation.walkthrough.first { $0.analyzerID == id })
            XCTAssertEqual(entry.status, .notApplicable)
            XCTAssertTrue(entry.text.contains("doesn't apply"), entry.text)
            XCTAssertTrue(entry.text.contains("HEVC"), entry.text)
            XCTAssertFalse(entry.text.contains("nothing unusual"), entry.text)
        }

        // And the appendix lists them with no evidence counted.
        for entry in explanation.technicalAppendix where ["ela", "jpegghost", "doublecompression"].contains(entry.analyzerID) {
            XCTAssertEqual(entry.status, .notApplicable)
            XCTAssertEqual(entry.evidence, 0)
        }
    }

    func testNotApplicableChecksDoNotWeakenTheConclusion() throws {
        let findings = try heicFindings()
        let withThem = explain(findings, .brief)
        let without = explain(Array(findings.suffix(2)), .brief)
        XCTAssertEqual(withThem.headline, without.headline)
        XCTAssertTrue(withThem.summary.contains("2 of them could examine this image"), withThem.summary)
    }

    func testNothingAssessableReadsAsInconclusive() throws {
        let explanation = explain([
            AnalyzerFinding(analyzerID: "ela", score: 0, summary: "Could not run Error Level Analysis: Analyzer cannot run on this input: ELA requires decoded pixel data.", indicators: []),
            .clean(analyzerID: "thumbnail", summary: "The file has no EXIF data. EXIF thumbnail consistency is not applicable."),
            .clean(analyzerID: "prnu", summary: "Image is too small for a sensor-noise consistency check: it needs at least 4 blocks of 64x64 px."),
        ])
        XCTAssertTrue(explanation.headline.hasPrefix("Inconclusive"), explanation.headline)
        XCTAssertTrue(explanation.summary.contains("not the same as the image being authentic"), explanation.summary)
        XCTAssertTrue(explanation.keyFindings.isEmpty)
        XCTAssertFalse(explanation.caveats.contains { $0.contains("isn't proof the image is untouched") }, "a clean-result caveat would be misleading here")

        let caveat = try XCTUnwrap(explanation.caveats.first { $0.hasPrefix("No check could examine") }, "\(explanation.caveats)")
        XCTAssertTrue(caveat.contains("1 doesn't apply"), caveat)
        XCTAssertTrue(caveat.contains("1 couldn't reach a reliable answer"), caveat)
        XCTAssertTrue(caveat.contains("1 couldn't run"), caveat)
    }

    func testFailedCheckShowsTheReasonWithoutTheEnginePrefix() throws {
        let explanation = explain([
            AnalyzerFinding(analyzerID: "ela", score: 0, summary: "Could not run Error Level Analysis: Analyzer cannot run on this input: ELA requires decoded pixel data.", indicators: []),
            AnalyzerFinding(analyzerID: "clone", score: 50, summary: "Duplicated region.", indicators: []),
        ])
        let entry = try XCTUnwrap(explanation.walkthrough.first { $0.analyzerID == "ela" })
        XCTAssertEqual(entry.status, .failed)
        XCTAssertTrue(entry.text.contains("couldn't run"), entry.text)
        XCTAssertTrue(entry.text.contains("Analyzer cannot run on this input"), entry.text)
        XCTAssertFalse(entry.text.contains("Could not run Error Level Analysis:"), entry.text)
    }

    func testFewAssessableChecksAreCalledOut() {
        let notApplicable = "This check is not applicable."
        let explanation = explain([
            .clean(analyzerID: "ela", summary: notApplicable),
            .clean(analyzerID: "jpegghost", summary: notApplicable),
            .clean(analyzerID: "doublecompression", summary: notApplicable),
            AnalyzerFinding(analyzerID: "clone", score: 60, summary: "Duplicated region.", indicators: []),
        ], .brief)
        XCTAssertTrue(explanation.caveats.contains { $0.contains("Only 1 of 4 checks") }, "\(explanation.caveats)")
    }
}
