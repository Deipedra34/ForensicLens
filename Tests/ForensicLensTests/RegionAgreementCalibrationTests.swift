import XCTest
@testable import ForensicLens

/// The region-overlap step of calibration: detectors from independent
/// evidence families that flag the same area raise the confidence; the
/// same findings in different places, or from the same family, don't.
final class RegionAgreementCalibrationTests: XCTestCase {
    private let calibrator = ConfidenceCalibrator()
    private let block = Region(x: 128, y: 64, width: 64, height: 64)
    private let elsewhere = Region(x: 0, y: 192, width: 64, height: 64)

    private func flagged(_ id: String, _ score: Double, _ regions: [Region]) -> AnalyzerFinding {
        AnalyzerFinding(analyzerID: id, score: score, summary: "\(id) flagged something.",
                        indicators: [Indicator(message: "\(id) indicator", weight: score, regions: regions)])
    }

    func testIndependentDetectorsAgreeingOnOneAreaBoostConfidence() throws {
        // PRNU 0.6 x 0.8 = 0.48 and CFA 0.6 x 0.7 = 0.42; without agreement
        // 1 - 0.52 x 0.58 = 0.6984. Agreement: two families, mean evidence
        // 0.45, boost 0.5 x 1 x 0.45 = 0.225, so 1 - 0.3016 x 0.775 = 0.7663.
        let agreeing = calibrator.calibrate([flagged("prnu", 60, [block]), flagged("cfa", 60, [block])])
        XCTAssertEqual(agreeing.score, 76.6, accuracy: 0.05)

        let agreement = try XCTUnwrap(agreeing.agreements.first)
        XCTAssertEqual(agreeing.agreements.count, 1)
        XCTAssertEqual(agreement.analyzerIDs, ["cfa", "prnu"])
        XCTAssertEqual(agreement.families, [.demosaicing, .sensorNoise])
        XCTAssertEqual(agreement.region, block)
        XCTAssertEqual(agreement.boost, 0.225, accuracy: 1e-9)
        XCTAssertTrue(agreement.applied)

        // The same two findings in different places: no boost.
        let apart = calibrator.calibrate([flagged("prnu", 60, [block]), flagged("cfa", 60, [elsewhere])])
        XCTAssertEqual(apart.score, 69.8, accuracy: 0.05)
        XCTAssertTrue(apart.agreements.isEmpty)
        XCTAssertGreaterThan(agreeing.score, apart.score)
    }

    func testDetectorsReadingTheSameTraceDoNotCountAsIndependent() {
        // PRNU and the noise-level check both read sensor noise: 1 - 0.52 x 0.8.
        let sameFamily = calibrator.calibrate([flagged("prnu", 60, [block]), flagged("noiselevel", 40, [block])])
        XCTAssertEqual(sameFamily.score, 58.4, accuracy: 0.05)
        XCTAssertTrue(sameFamily.agreements.isEmpty)

        // ELA and JPEG ghost both read compression history.
        let compression = calibrator.calibrate([flagged("ela", 50, [block]), flagged("jpegghost", 50, [block])])
        XCTAssertTrue(compression.agreements.isEmpty)
    }

    func testWholeImageDetectorsDoNotTakePartInAgreement() {
        // The AI-generated image check describes the whole file, even if a
        // region happens to be attached.
        let confidence = calibrator.calibrate([flagged("prnu", 60, [block]), flagged("aigenerated", 75, [block])])
        XCTAssertTrue(confidence.agreements.isEmpty)
        // 1 - 0.52 x 0.5
        XCTAssertEqual(confidence.score, 74, accuracy: 0.05)
    }

    func testRegionsMustOverlapByAQuarterOfTheSmallerOne() {
        let corner = Region(x: 0, y: 0, width: 64, height: 64)
        let barelyTouching = Region(x: 56, y: 56, width: 64, height: 64) // 8x8 overlap: 1.6%
        let halfOverlapping = Region(x: 32, y: 0, width: 64, height: 64)  // 32x64 overlap: 50%
        let insideIt = Region(x: 16, y: 16, width: 16, height: 16)        // fully inside: 100% of the smaller

        XCTAssertFalse(RegionClustering.overlaps(corner, barelyTouching))
        XCTAssertTrue(RegionClustering.overlaps(corner, halfOverlapping))
        XCTAssertTrue(RegionClustering.overlaps(corner, insideIt))
        XCTAssertFalse(RegionClustering.overlaps(corner, Region(x: 64, y: 0, width: 64, height: 64)), "edges touching isn't overlap")

        XCTAssertTrue(calibrator.calibrate([flagged("prnu", 60, [corner]), flagged("cfa", 60, [barelyTouching])]).agreements.isEmpty)
        XCTAssertFalse(calibrator.calibrate([flagged("prnu", 60, [corner]), flagged("ela", 60, [insideIt])]).agreements.isEmpty)
    }

    func testThreeFamiliesAgreeingBoostMoreThanTwo() throws {
        let two = calibrator.calibrate([flagged("prnu", 60, [block]), flagged("cfa", 60, [block])])
        let three = calibrator.calibrate([flagged("prnu", 60, [block]), flagged("cfa", 60, [block]), flagged("clone", 90, [block])])
        let agreement = try XCTUnwrap(three.agreements.first)
        XCTAssertEqual(agreement.families.count, 3)
        // Mean evidence (0.48 + 0.42 + 0.855) / 3 = 0.585; boost 0.5 x 2 x 0.585.
        XCTAssertEqual(agreement.boost, 0.585, accuracy: 1e-9)
        XCTAssertEqual(three.score, 98.2, accuracy: 0.05)
        XCTAssertGreaterThan(three.score, two.score)
    }

    func testBoostIsCapped() throws {
        let strongest = DetectorProfile.builtIn.filter(\.localizes).map { flagged($0.analyzerID, $0.scoreCeiling, [block]) }
        let agreement = try XCTUnwrap(calibrator.calibrate(strongest).agreements.first)
        XCTAssertEqual(agreement.boost, ConfidenceCalibrator.maximumAgreementBoost, accuracy: 1e-9)
    }

    func testOnlyTheStrongestAgreeingAreaIsApplied() {
        // PRNU and CFA agree on two separate areas: listed twice, applied once.
        let twice = calibrator.calibrate([flagged("prnu", 60, [block, elsewhere]), flagged("cfa", 60, [block, elsewhere])])
        XCTAssertEqual(twice.agreements.count, 2)
        XCTAssertEqual(twice.agreements.filter(\.applied).count, 1)
        XCTAssertEqual(twice.score, 76.6, accuracy: 0.05)
    }

    func testCloneSourceAndCopyCanEachMatchADifferentDetector() {
        // Clone detection reports both the source and the pasted copy; a
        // CFA flag on the copy agrees with it.
        let source = Region(x: 8, y: 8, width: 24, height: 24)
        let copy = Region(x: 88, y: 88, width: 24, height: 24)
        let confidence = calibrator.calibrate([flagged("clone", 80, [source, copy]), flagged("cfa", 50, [Region(x: 80, y: 80, width: 32, height: 32)])])
        XCTAssertEqual(confidence.agreements.count, 1)
        XCTAssertEqual(confidence.agreements.first?.analyzerIDs, ["cfa", "clone"])
    }
}
