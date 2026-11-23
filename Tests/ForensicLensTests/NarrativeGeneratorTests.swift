import XCTest
@testable import ForensicLens

/// The narrative for synthetic multi-detector results. These check that the
/// right detectors, regions, and caveats are mentioned and the structure is
/// right -- not exact sentences, which are free to be reworded.
final class NarrativeGeneratorTests: XCTestCase {
    private let size = ImageSize(width: 256, height: 256)
    private let block = Region(x: 128, y: 64, width: 64, height: 64)
    private let cloneSource = Region(x: 8, y: 8, width: 24, height: 24)
    private let cloneCopy = Region(x: 88, y: 88, width: 24, height: 24)

    private func flagged(_ id: String, _ score: Double, _ regions: [Region] = [], message: String? = nil) -> AnalyzerFinding {
        AnalyzerFinding(analyzerID: id, score: score, summary: "\(id) flagged something.",
                        indicators: [Indicator(message: message ?? "\(id) indicator", weight: score, regions: regions)])
    }

    private func clean(_ id: String) -> AnalyzerFinding {
        .clean(analyzerID: id, summary: "Nothing unusual found.")
    }

    /// A spliced block that sensor-noise and color-pattern analysis both
    /// flag, a copy-move clone elsewhere, an editing-software tag, and two
    /// checks that found nothing.
    private var tamperedFindings: [AnalyzerFinding] {
        [
            clean("ela"),
            flagged("metadata", 35, message: "Software tag reports \"Adobe Photoshop 25.0\", which matches known editing tool signature \"photoshop\"."),
            flagged("clone", 80, [cloneSource, cloneCopy]),
            flagged("prnu", 60, [block]),
            flagged("cfa", 60, [block]),
            clean("noiselevel"),
        ]
    }

    private func explain(_ findings: [AnalyzerFinding], _ verbosity: NarrativeVerbosity = .brief, size: ImageSize? = nil) -> (ReportExplanation, CalibratedConfidence) {
        let confidence = ConfidenceCalibrator().calibrate(findings)
        return (NarrativeGenerator(verbosity: verbosity).explain(findings: findings, confidence: confidence, imageSize: size), confidence)
    }

    // MARK: - A multi-signal tampered image

    func testAgreeingAreaComesFirstAndNamesBothDetectorsAndTheRegion() throws {
        let (explanation, confidence) = explain(tamperedFindings, size: size)
        XCTAssertEqual(confidence.verdict, "likely manipulated")
        XCTAssertTrue(explanation.headline.lowercased().contains("manipulated"), explanation.headline)

        let first = try XCTUnwrap(explanation.keyFindings.first)
        XCTAssertEqual(Set(first.analyzerIDs), ["prnu", "cfa"])
        XCTAssertEqual(first.regions, [block])
        XCTAssertTrue(first.text.contains("sensor-noise"), first.text)
        XCTAssertTrue(first.text.contains("color-pattern"), first.text)
        XCTAssertTrue(first.text.contains("x 128-192, y 64-128"), first.text)
        XCTAssertTrue(first.text.contains("agree"), first.text)
    }

    func testEachFlaggedDetectorIsExplainedWithItsRegionsOrDetail() throws {
        // Full verbosity: brief lists only the three strongest checks on
        // their own (see testBriefListsOnlyTheStrongestFewDetectors).
        let (explanation, _) = explain(tamperedFindings, .full, size: size)

        let clone = try XCTUnwrap(explanation.keyFindings.first { $0.analyzerIDs == ["clone"] })
        XCTAssertTrue(clone.text.contains("copied and pasted"), clone.text)
        XCTAssertTrue(clone.text.contains("x 8-32, y 8-32"), clone.text)
        XCTAssertTrue(clone.text.contains("x 88-112, y 88-112"), clone.text)
        XCTAssertEqual(clone.regions, [cloneSource, cloneCopy])

        // Metadata points at the whole file, so it quotes its strongest indicator instead.
        let metadata = try XCTUnwrap(explanation.keyFindings.first { $0.analyzerIDs == ["metadata"] })
        XCTAssertTrue(metadata.text.contains("Adobe Photoshop 25.0"), metadata.text)
        XCTAssertTrue(metadata.regions.isEmpty)

        // Checks that found nothing aren't key findings.
        XCTAssertFalse(explanation.keyFindings.contains { $0.analyzerIDs.contains("ela") || $0.analyzerIDs.contains("noiselevel") })
    }

    func testSummaryStatesHowManyChecksRanAndTheCalibratedScore() {
        let (explanation, confidence) = explain(tamperedFindings)
        XCTAssertTrue(explanation.summary.contains("6 checks"), explanation.summary)
        XCTAssertTrue(explanation.summary.contains("\(NarrativeGenerator.formatted(confidence.score))/100"), explanation.summary)
        XCTAssertTrue(explanation.summary.contains("independent checks point at the same area"), explanation.summary)
    }

    func testTechnicalAppendixHasEveryDetectorsRawNumbers() throws {
        let findings = tamperedFindings
        for verbosity in NarrativeVerbosity.allCases {
            let (explanation, _) = explain(findings, verbosity)
            XCTAssertEqual(explanation.technicalAppendix.map(\.analyzerID), findings.map(\.analyzerID))
            let clone = try XCTUnwrap(explanation.technicalAppendix.first { $0.analyzerID == "clone" })
            XCTAssertEqual(clone.rawScore, 80)
            XCTAssertEqual(clone.normalizedStrength, 0.8, accuracy: 1e-9)
            XCTAssertEqual(clone.reliability, 0.95)
            XCTAssertEqual(clone.evidence, 0.76, accuracy: 1e-9)
            XCTAssertEqual(clone.status, .flagged)
            XCTAssertEqual(clone.summary, "clone flagged something.")
        }
    }

    // MARK: - Verbosity

    func testBriefHasNoWalkthroughAndFullCoversEveryDetectorInOrder() throws {
        let findings = tamperedFindings
        XCTAssertTrue(explain(findings, .brief).0.walkthrough.isEmpty)

        let (full, _) = explain(findings, .full, size: size)
        XCTAssertEqual(full.verbosity, .full)
        XCTAssertEqual(full.walkthrough.map(\.analyzerID), findings.map(\.analyzerID))
        let clone = try XCTUnwrap(full.walkthrough.first { $0.analyzerID == "clone" })
        XCTAssertEqual(clone.status, .flagged)
        XCTAssertTrue(clone.text.contains("80/100"), clone.text)
        XCTAssertTrue(clone.text.contains("76/100"), clone.text)
        let ela = try XCTUnwrap(full.walkthrough.first { $0.analyzerID == "ela" })
        XCTAssertEqual(ela.status, .clean)
        XCTAssertTrue(ela.text.contains("nothing unusual"), ela.text)
    }

    func testBriefListsOnlyTheStrongestFewDetectors() {
        let five = [flagged("clone", 90), flagged("prnu", 70), flagged("ela", 60), flagged("metadata", 40), flagged("noiselevel", 30)]
        let (brief, _) = explain(five, .brief)
        let perDetector = brief.keyFindings.filter { $0.analyzerIDs.count == 1 }
        XCTAssertEqual(perDetector.prefix(3).map { $0.analyzerIDs[0] }, ["clone", "prnu", "ela"])
        let rest = brief.keyFindings.last
        XCTAssertEqual(rest.map { Set($0.analyzerIDs) }, ["metadata", "noiselevel"])

        let (full, _) = explain(five, .full)
        XCTAssertEqual(full.keyFindings.count, 5)
    }

    // MARK: - Caveats

    func testCleanResultIsNotPresentedAsProof() {
        let (explanation, _) = explain(["ela", "clone", "prnu"].map(clean))
        XCTAssertTrue(explanation.headline.contains("No signs"), explanation.headline)
        XCTAssertTrue(explanation.keyFindings.isEmpty)
        XCTAssertTrue(explanation.caveats.contains { $0.contains("isn't proof") }, "\(explanation.caveats)")
    }

    func testEvidenceFromOnlyAFalsePositiveProneCheckIsFlaggedAsSuch() {
        let (explanation, confidence) = explain([flagged("noiselevel", 80, [block]), clean("prnu"), clean("clone")])
        XCTAssertEqual(confidence.score, 40, accuracy: 0.05)
        let caveat = explanation.caveats.first { $0.contains("noise-level check") }
        XCTAssertNotNil(caveat, "\(explanation.caveats)")
        XCTAssertTrue(caveat?.contains("look closer") ?? false)
    }

    func testEverySetEndsWithTheSignalsNotProofCaveat() {
        for findings in [tamperedFindings, [clean("ela")], []] {
            XCTAssertTrue(explain(findings).0.caveats.last?.contains("not proof") ?? false)
        }
    }

    // MARK: - Regions and determinism

    func testRegionsAreDescribedByWhereTheyAreInThePicture() {
        XCTAssertTrue(RegionDescriber.describe(Region(x: 0, y: 0, width: 32, height: 32), in: size).contains("upper left"))
        XCTAssertTrue(RegionDescriber.describe(Region(x: 200, y: 200, width: 32, height: 32), in: size).contains("lower right"))
        XCTAssertTrue(RegionDescriber.describe(Region(x: 112, y: 112, width: 32, height: 32), in: size).contains("center"))
        XCTAssertTrue(RegionDescriber.describe(Region(x: 0, y: 0, width: 240, height: 240), in: size).contains("most of the image"))
        XCTAssertEqual(RegionDescriber.describe(block, in: nil), "an area of 64x64 pixels at x 128-192, y 64-128")
        XCTAssertEqual(RegionDescriber.list([block, block, block, block, block], in: nil, limit: 2).components(separatedBy: "an area").count - 1, 2)
        XCTAssertTrue(RegionDescriber.list([block, block, block], in: nil, limit: 2).hasSuffix("and 1 more area"))
        XCTAssertEqual(RegionDescriber.joined(["a", "b", "c"]), "a, b, and c")
    }

    func testRunsOfOverlappingBlocksAreDescribedAsOneArea() throws {
        // Block matching reports a 32px copied patch as 16px blocks every 8px.
        var source: [Region] = []
        var copy: [Region] = []
        for y in stride(from: 16, through: 32, by: 8) {
            for x in stride(from: 16, through: 32, by: 8) {
                source.append(Region(x: x, y: y, width: 16, height: 16))
                copy.append(Region(x: x, y: y + 160, width: 16, height: 16))
            }
        }
        XCTAssertEqual(RegionDescriber.merged(source + copy), [Region(x: 16, y: 16, width: 32, height: 32), Region(x: 16, y: 176, width: 32, height: 32)])

        let (explanation, _) = explain([flagged("clone", 90, source + copy)], size: size)
        let clone = try XCTUnwrap(explanation.keyFindings.first { $0.analyzerIDs == ["clone"] })
        XCTAssertEqual(clone.regions.count, 2)
        XCTAssertTrue(clone.text.contains("32x32 pixels"), clone.text)
        XCTAssertFalse(clone.text.contains("more area"), clone.text)
    }

    func testRegionsOfVeryDifferentSizesAreNotMerged() {
        let small = Region(x: 0, y: 0, width: 16, height: 16)
        let large = Region(x: 8, y: 8, width: 120, height: 120)
        XCTAssertEqual(RegionDescriber.merged([small, large]), [small, large])
        let apart = Region(x: 64, y: 64, width: 16, height: 16)
        XCTAssertEqual(RegionDescriber.merged([small, apart]), [small, apart])
    }

    func testTheSameResultsAlwaysGiveTheSameNarrative() {
        XCTAssertEqual(explain(tamperedFindings, .full, size: size).0, explain(tamperedFindings, .full, size: size).0)
    }
}
