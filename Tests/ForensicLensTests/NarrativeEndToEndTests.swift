import XCTest
import ImageDecoding
@testable import ForensicLens

/// The whole pipeline on a synthetic tampered image with more than one
/// planted signal: every detector runs through the engine, and the report's
/// calibrated confidence and narrative must point at the right detectors and
/// the right area. Checked by key terms and structure, not exact wording.
final class NarrativeEndToEndTests: XCTestCase {
    private let splice = Region(x: 128, y: 64, width: 64, height: 64)

    /// A simulated Bayer capture (see `CFAFixtures.swift`) with a block of
    /// random pixels spliced in at `splice`, which has no demosaicing
    /// pattern, plus a patch of noise copied from (16,16) to (16,176): a
    /// copy-move forgery.
    private func tamperedImage() throws -> ImageData {
        let capture = try Fixtures.demosaicedCapture(width: 256, height: 256, sceneSeed: 2, noiseSeed: 5)
        var buffer = try Fixtures.splicingCFA(.randomPixels(seed: 99), at: splice.x, splice.y, size: splice.width, into: capture)
        buffer = try Fixtures.stampingNoisePatch(of: 32, at: (x: 16, y: 16), into: buffer, seed: 7)
        buffer = try Fixtures.pastingPatch(of: 32, from: (x: 16, y: 16), to: (x: 16, y: 176), into: buffer)
        return try Fixtures.imageData(from: buffer)
    }

    private func run(_ image: ImageData, verbosity: NarrativeVerbosity = .full) -> ForensicReport {
        var config = ForensicLensConfig.default
        config.report.narrativeVerbosity = verbosity
        return ForensicLensEngine(config: config).run(on: image)
    }

    func testEngineExplainsAMultiSignalTamperedImage() throws {
        let report = run(try tamperedImage())
        let confidence = try XCTUnwrap(report.confidence)
        let explanation = try XCTUnwrap(report.explanation)

        // Both planted signals were found by their detectors.
        let clone = try XCTUnwrap(report.findings.first { $0.analyzerID == "clone" })
        let cfa = try XCTUnwrap(report.findings.first { $0.analyzerID == "cfa" })
        XCTAssertGreaterThan(clone.score, 0, clone.summary)
        XCTAssertGreaterThan(cfa.score, 0, cfa.summary)
        XCTAssertTrue(cfa.indicators.flatMap(\.regions).contains(splice))

        // The calibrated confidence reflects them, and the suspicion score is untouched.
        XCTAssertGreaterThanOrEqual(confidence.score, 45, "\(confidence)")
        XCTAssertNotEqual(confidence.verdict, "likely authentic")
        XCTAssertEqual(report.overallScore, SuspicionScorer().score(report.findings).overallScore)
        XCTAssertEqual(confidence.totalDetectors, report.findings.count)

        // The narrative names both detectors and the spliced area.
        XCTAssertFalse(explanation.headline.isEmpty)
        let cloneFinding = try XCTUnwrap(explanation.keyFindings.first { $0.analyzerIDs == ["clone"] }, "\(explanation.keyFindings)")
        XCTAssertTrue(cloneFinding.text.contains("copied and pasted"), cloneFinding.text)
        let cfaFindings = explanation.keyFindings.filter { $0.analyzerIDs.contains("cfa") }
        XCTAssertFalse(cfaFindings.isEmpty, "\(explanation.keyFindings)")
        XCTAssertTrue(cfaFindings.contains { finding in finding.regions.contains { $0.intersection(self.splice) != nil } })
        XCTAssertTrue(cfaFindings.contains { $0.text.contains("x 128-192, y 64-128") }, "\(cfaFindings)")
        XCTAssertTrue(cfaFindings.contains { $0.text.contains("color-pattern") })

        // The full walkthrough covers every detector the engine ran, in order.
        XCTAssertEqual(explanation.walkthrough.map(\.analyzerID), report.findings.map(\.analyzerID))
        XCTAssertEqual(explanation.technicalAppendix.map(\.analyzerID), report.findings.map(\.analyzerID))

        // And it all reaches the text report.
        let text = report.textReport
        XCTAssertTrue(text.contains("What this means"), text)
        XCTAssertTrue(text.contains("copy-paste check"), text)
        XCTAssertTrue(text.contains("Check by check:"), text)
        XCTAssertTrue(text.contains("Calibrated confidence:"), text)
    }

    func testEngineExplainsJPEGSpecificChecksAsNotApplyingToHEIF() throws {
        let image = ImageData(rawBytes: [], pixels: try Fixtures.noiseBuffer(width: 128, height: 128, seed: 4), format: .heif)
        let report = run(image)
        let confidence = try XCTUnwrap(report.confidence)
        let explanation = try XCTUnwrap(report.explanation)

        for id in ["ela", "jpegghost", "doublecompression"] {
            XCTAssertEqual(confidence.contributions.first { $0.analyzerID == id }?.status, .notApplicable, id)
            XCTAssertEqual(explanation.walkthrough.first { $0.analyzerID == id }?.status, .notApplicable, id)
        }
        XCTAssertLessThan(confidence.assessedDetectors, confidence.totalDetectors)
        XCTAssertTrue(explanation.caveats.contains { $0.contains("don't apply to this kind of image") }, "\(explanation.caveats)")
        XCTAssertFalse(explanation.keyFindings.contains { ["ela", "jpegghost", "doublecompression"].contains($0.analyzerIDs.first ?? "") })
    }

    func testNarrativeCanBeTurnedOffWhileKeepingTheCalibratedScore() throws {
        var config = ForensicLensConfig.default
        config.report.narrative = false
        let report = ForensicLensEngine(config: config).run(on: try tamperedImage())
        XCTAssertNil(report.explanation)
        XCTAssertNotNil(report.confidence)
        XCTAssertFalse(report.textReport.contains("What this means"))
    }
}
