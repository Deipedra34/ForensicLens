import XCTest
import ImageDecoding
@testable import ForensicLens

/// Detectors that don't apply, can't judge the image, or fail must be left
/// out of the calibrated confidence -- neither counted as evidence nor as a
/// clean result -- and a result set with nothing assessable must read as
/// inconclusive rather than authentic.
final class NotApplicableCalibrationTests: XCTestCase {
    private let calibrator = ConfidenceCalibrator()

    private func finding(_ id: String, score: Double = 0, _ summary: String) -> AnalyzerFinding {
        AnalyzerFinding(analyzerID: id, score: score, summary: summary, indicators: [])
    }

    // MARK: - Classification

    func testStatusIsReadFromTheFindingsOwnWording() {
        let cases: [(String, Double, DetectorStatus)] = [
            ("HEIF/HEIC images are compressed with HEVC, not JPEG, so there's no JPEG compression history to analyze; Error Level Analysis is not applicable.", 0, .notApplicable),
            ("BMP format does not carry EXIF metadata; nothing to analyze.", 0, .notApplicable),
            ("Grayscale image: there are no color channels to carry a demosaicing pattern, so CFA analysis is not applicable.", 0, .notApplicable),
            ("The file has no embedded EXIF thumbnail. EXIF thumbnail consistency is not applicable.", 0, .notApplicable),
            ("Image is too small for a CFA consistency check: it needs at least 4 blocks of 64x64 px.", 0, .notAssessed),
            ("Not assessed (low confidence): the image is too small, flat or clipped for either the spectral or the sensor-noise check.", 0, .notAssessed),
            ("Image is smaller than one comparison block; nothing to compare.", 0, .notAssessed),
            ("Could not run Error Level Analysis: Analyzer cannot run on this input: ELA requires decoded pixel data.", 0, .failed),
            ("No duplicated regions detected.", 0, .clean),
            ("Noise level is consistent across all 16 analyzed block(s) (typical noise 2.1 gray levels).", 0, .clean),
            ("2 region(s) flagged.", 45, .flagged),
            ("1 weak block.", 1, .flagged),
            // Below one point: shown as 0/100 everywhere, so not a signal.
            ("No cross-quality-consistent error-level anomalies detected (mean 0.0).", 0.4, .clean),
            ("Image is too small for a CFA consistency check.", 0.2, .notAssessed),
        ]
        for (summary, score, expected) in cases {
            XCTAssertEqual(DetectorStatus.classify(finding("x", score: score, summary)), expected, summary)
        }
        XCTAssertTrue(DetectorStatus.flagged.isAssessed)
        XCTAssertTrue(DetectorStatus.clean.isAssessed)
        XCTAssertFalse(DetectorStatus.notApplicable.isAssessed)
        XCTAssertFalse(DetectorStatus.notAssessed.isAssessed)
        XCTAssertFalse(DetectorStatus.failed.isAssessed)
    }

    func testRealJPEGSpecificFindingsOnHEIFAndWebPClassifyAsNotApplicable() throws {
        let pixels = try Fixtures.noiseBuffer(width: 128, height: 128, seed: 3)
        for format in [ImageFormat.heif, .webp] {
            let image = ImageData(rawBytes: [], pixels: pixels, format: format)
            for analyzer in [ELAAnalyzer(), JPEGGhostAnalyzer(), DoubleCompressionAnalyzer()] as [any Analyzer] {
                let finding = try analyzer.analyze(image, config: .default)
                XCTAssertEqual(DetectorStatus.classify(finding), .notApplicable, finding.summary)
            }
        }
    }

    func testRealFindingsOnATinyImageClassifyAsNotAssessed() throws {
        let image = try Fixtures.imageData(from: Fixtures.noiseBuffer(width: 40, height: 40, seed: 2))
        for analyzer in [PRNUAnalyzer(), CFAAnalyzer(), NoiseLevelAnalyzer(), JPEGGhostAnalyzer()] as [any Analyzer] {
            let finding = try analyzer.analyze(image, config: .default)
            XCTAssertEqual(DetectorStatus.classify(finding), .notAssessed, "\(analyzer.identifier): \(finding.summary)")
        }
    }

    // MARK: - Calibration

    func testNotApplicableDetectorsNeitherAddNorDiluteEvidence() throws {
        // A HEIC: the three JPEG-specific detectors don't apply.
        let notApplicable = "HEIF/HEIC images are compressed with HEVC, not JPEG, so there's no JPEG compression history to analyze; this check is not applicable."
        let heic = [
            finding("ela", notApplicable),
            finding("jpegghost", notApplicable),
            finding("doublecompression", notApplicable),
            AnalyzerFinding(analyzerID: "clone", score: 90, summary: "1 duplicated region.", indicators: []),
            finding("prnu", "Sensor noise is consistent across all 16 analyzed block(s)."),
        ]
        let confidence = calibrator.calibrate(heic)
        // Exactly clone detection's 0.9 x 0.95, as if the others weren't there.
        XCTAssertEqual(confidence.score, 85.5, accuracy: 0.05)
        XCTAssertEqual(confidence.score, calibrator.calibrate([heic[3]]).score)
        XCTAssertEqual(confidence.assessedDetectors, 2)
        XCTAssertEqual(confidence.totalDetectors, 5)

        let ela = try XCTUnwrap(confidence.contributions.first { $0.analyzerID == "ela" })
        XCTAssertEqual(ela.status, .notApplicable)
        XCTAssertEqual(ela.evidence, 0)
        XCTAssertEqual(ela.normalizedStrength, 0)
    }

    func testNothingAssessableIsInconclusiveNotAuthentic() {
        let confidence = calibrator.calibrate([
            finding("ela", "Could not run Error Level Analysis: Analyzer cannot run on this input: ELA requires decoded pixel data."),
            finding("thumbnail", "The file has no EXIF data. EXIF thumbnail consistency is not applicable."),
            finding("prnu", "Image is too small for a sensor-noise consistency check: it needs at least 4 blocks of 64x64 px."),
        ])
        XCTAssertEqual(confidence.score, 0)
        XCTAssertEqual(confidence.verdict, CalibratedConfidence.inconclusiveVerdict)
        XCTAssertTrue(confidence.isInconclusive)
        XCTAssertEqual(confidence.assessedDetectors, 0)
        XCTAssertEqual(confidence.totalDetectors, 3)
    }

    func testNoFindingsAtAllIsInconclusive() {
        let confidence = calibrator.calibrate([])
        XCTAssertEqual(confidence.score, 0)
        XCTAssertTrue(confidence.isInconclusive)
        XCTAssertTrue(confidence.contributions.isEmpty)
        XCTAssertTrue(confidence.agreements.isEmpty)
    }

    func testFailedDetectorsDoNotFormAgreements() {
        let block = Region(x: 0, y: 0, width: 64, height: 64)
        // A failed finding carries no regions anyway, but even a stray score
        // on a "Could not run" finding isn't trusted.
        let confidence = calibrator.calibrate([
            AnalyzerFinding(analyzerID: "prnu", score: 60, summary: "Could not run PRNU Sensor Noise Analysis: failed.", indicators: [Indicator(message: "x", weight: 60, regions: [block])]),
            AnalyzerFinding(analyzerID: "cfa", score: 60, summary: "1 block flagged.", indicators: [Indicator(message: "y", weight: 60, regions: [block])]),
        ])
        XCTAssertTrue(confidence.agreements.isEmpty)
        XCTAssertEqual(confidence.score, 42, accuracy: 0.05)
    }
}
