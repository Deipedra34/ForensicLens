import XCTest
@testable import ForensicLens

/// The calibration rule on synthetic findings with hand-worked expected
/// scores: normalization against each detector's ceiling, reliability
/// weighting, and the `1 - product(1 - e)` combination.
final class ConfidenceCalibrationTests: XCTestCase {
    private let calibrator = ConfidenceCalibrator()

    private func flagged(_ id: String, _ score: Double, regions: [Region] = []) -> AnalyzerFinding {
        AnalyzerFinding(analyzerID: id, score: score, summary: "\(id) flagged something.",
                        indicators: [Indicator(message: "\(id) indicator", weight: score, regions: regions)])
    }

    private func clean(_ id: String) -> AnalyzerFinding {
        .clean(analyzerID: id, summary: "Nothing unusual found.")
    }

    // MARK: - Normalization

    func testScoresAreNormalizedAgainstEachDetectorsOwnCeiling() {
        func strength(_ id: String, _ raw: Double) -> Double {
            ScoreNormalizer.normalizedStrength(rawScore: raw, profile: .profile(for: id))
        }
        // Each detector's strongest possible finding is 1.0, whatever its raw scale.
        XCTAssertEqual(strength("noiselevel", 80), 1, accuracy: 1e-9)
        XCTAssertEqual(strength("aigenerated", 75), 1, accuracy: 1e-9)
        XCTAssertEqual(strength("thumbnail", 90), 1, accuracy: 1e-9)
        XCTAssertEqual(strength("clone", 100), 1, accuracy: 1e-9)
        // The same raw score means different strengths on different scales.
        XCTAssertEqual(strength("noiselevel", 40), 0.5, accuracy: 1e-9)
        XCTAssertEqual(strength("clone", 40), 0.4, accuracy: 1e-9)
        XCTAssertEqual(strength("thumbnail", 45), 0.5, accuracy: 1e-9)
        // Out-of-range and non-finite input is clamped, not propagated.
        XCTAssertEqual(strength("clone", 150), 1)
        XCTAssertEqual(strength("clone", -5), 0)
        XCTAssertEqual(strength("clone", .nan), 0)
    }

    func testUnknownAnalyzersGetANeutralProfile() {
        let profile = DetectorProfile.profile(for: "custom-check")
        XCTAssertEqual(profile.family, .other)
        XCTAssertEqual(profile.scoreCeiling, 100)
        XCTAssertEqual(profile.reliability, DetectorProfile.defaultReliability)
        XCTAssertFalse(profile.localizes)
        XCTAssertEqual(calibrator.calibrate([flagged("custom-check", 60)]).score, 30, accuracy: 0.05)
    }

    func testEveryBuiltInAnalyzerHasAProfile() {
        let engineIDs = ForensicLensEngine(config: .default).availableAnalyzerIDs
        XCTAssertEqual(DetectorProfile.builtIn.map(\.analyzerID), engineIDs)
        for profile in DetectorProfile.builtIn {
            XCTAssertGreaterThan(profile.reliability, 0, profile.analyzerID)
            XCTAssertLessThanOrEqual(profile.reliability, 1, profile.analyzerID)
            XCTAssertFalse(profile.reliabilityNote.isEmpty, profile.analyzerID)
        }
    }

    // MARK: - Weighting

    func testSingleReliableDetector() {
        let confidence = calibrator.calibrate([flagged("clone", 90)])
        // 0.9 normalized x 0.95 reliability.
        XCTAssertEqual(confidence.score, 85.5, accuracy: 0.05)
        XCTAssertEqual(confidence.verdict, "likely manipulated")
    }

    func testFalsePositiveProneDetectorIsDownweighted() {
        // The noise-level check's strongest possible finding...
        let noiseOnly = [flagged("noiselevel", 80)]
        // ...scores 80 raw ("likely manipulated") on the suspicion score,
        XCTAssertEqual(SuspicionScorer().score(noiseOnly).overallScore, 80)
        // ...but only 1.0 x 0.4 = 40 calibrated, since its documented false
        // positives are common.
        let calibrated = calibrator.calibrate(noiseOnly)
        XCTAssertEqual(calibrated.score, 40, accuracy: 0.05)
        XCTAssertEqual(calibrated.verdict, "minor anomalies")

        // Clone detection at the same normalized strength keeps nearly all of it.
        XCTAssertEqual(calibrator.calibrate([flagged("clone", 100)]).score, 95, accuracy: 0.05)

        // Ordering across the board: equal normalized strength, ranked by reliability.
        let ranked = ["clone", "thumbnail", "prnu", "cfa", "ela", "aigenerated", "noiselevel"].map { id -> Double in
            let profile = DetectorProfile.profile(for: id)
            return calibrator.calibrate([flagged(id, profile.scoreCeiling)]).score
        }
        XCTAssertEqual(ranked, ranked.sorted(by: >))
    }

    func testContributionsRecordEachStep() throws {
        let confidence = calibrator.calibrate([flagged("clone", 90), clean("ela")])
        let clone = try XCTUnwrap(confidence.contributions.first { $0.analyzerID == "clone" })
        XCTAssertEqual(clone.status, .flagged)
        XCTAssertEqual(clone.rawScore, 90)
        XCTAssertEqual(clone.normalizedStrength, 0.9, accuracy: 1e-9)
        XCTAssertEqual(clone.reliability, 0.95)
        XCTAssertEqual(clone.evidence, 0.855, accuracy: 1e-9)

        let ela = try XCTUnwrap(confidence.contributions.first { $0.analyzerID == "ela" })
        XCTAssertEqual(ela.status, .clean)
        XCTAssertEqual(ela.evidence, 0)
        XCTAssertEqual(confidence.assessedDetectors, 2)
        XCTAssertEqual(confidence.totalDetectors, 2)
    }

    // MARK: - Combination

    func testIndependentSignalsCombineWithoutExceedingOneHundred() {
        // 1 - (1 - 0.855)(1 - 0.21) = 0.88545
        XCTAssertEqual(calibrator.calibrate([flagged("clone", 90), flagged("metadata", 35)]).score, 88.5, accuracy: 0.05)

        let everything = DetectorProfile.builtIn.map { flagged($0.analyzerID, $0.scoreCeiling) }
        let all = calibrator.calibrate(everything)
        XCTAssertLessThanOrEqual(all.score, 100)
        XCTAssertGreaterThan(all.score, 99)
    }

    func testSeveralWeakSignalsStayWellBelowTheirSum() {
        // ELA 0.5 x 0.6, noise level 0.5 x 0.4, metadata 0.2 x 0.6:
        // 1 - 0.7 x 0.8 x 0.88 = 0.5072.
        let weak = [flagged("ela", 50), flagged("noiselevel", 40), flagged("metadata", 20)]
        XCTAssertEqual(calibrator.calibrate(weak).score, 50.7, accuracy: 0.05)
        XCTAssertLessThan(calibrator.calibrate(weak).score, 50 + 40 + 20)
    }

    func testCombinationIsOrderIndependent() {
        let findings = [flagged("clone", 70), flagged("ela", 40), flagged("prnu", 55), clean("cfa")]
        XCTAssertEqual(calibrator.calibrate(findings).score, calibrator.calibrate(findings.reversed()).score)
    }

    func testAllCleanFindingsScoreZero() {
        let confidence = calibrator.calibrate(["ela", "clone", "prnu"].map(clean))
        XCTAssertEqual(confidence.score, 0)
        XCTAssertEqual(confidence.verdict, "likely authentic")
        XCTAssertEqual(confidence.assessedDetectors, 3)
        XCTAssertFalse(confidence.isInconclusive)
    }
}
