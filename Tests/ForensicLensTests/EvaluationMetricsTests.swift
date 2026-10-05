import XCTest
@testable import forensiclens_eval

/// Covers `ClassificationMetrics.swift` with hand-built confusion matrices
/// and score lists whose expected precision/recall/F1 are worked out by
/// hand -- no dataset or image decoding involved.
final class EvaluationMetricsTests: XCTestCase {
    private let accuracy = 1e-9

    // MARK: - Confusion matrix metrics

    func testMetricsForAMixedConfusionMatrix() {
        let matrix = ConfusionMatrix(truePositives: 8, falsePositives: 2, trueNegatives: 85, falseNegatives: 5)

        XCTAssertEqual(matrix.total, 100)
        XCTAssertEqual(matrix.precision, 0.8, accuracy: accuracy)          // 8 / 10
        XCTAssertEqual(matrix.recall, 8.0 / 13.0, accuracy: accuracy)      // 8 / 13
        XCTAssertEqual(matrix.f1, 16.0 / 23.0, accuracy: accuracy)         // 2TP / (2TP + FP + FN)
        XCTAssertEqual(matrix.accuracy, 0.93, accuracy: accuracy)          // 93 / 100
    }

    func testPerfectClassifierScoresOneEverywhere() {
        let matrix = ConfusionMatrix(truePositives: 5, falsePositives: 0, trueNegatives: 5, falseNegatives: 0)

        XCTAssertEqual(matrix.precision, 1)
        XCTAssertEqual(matrix.recall, 1)
        XCTAssertEqual(matrix.f1, 1)
        XCTAssertEqual(matrix.accuracy, 1)
    }

    func testFlaggingEverythingGivesFullRecallButHalfPrecision() {
        let matrix = ConfusionMatrix(truePositives: 4, falsePositives: 4, trueNegatives: 0, falseNegatives: 0)

        XCTAssertEqual(matrix.precision, 0.5, accuracy: accuracy)
        XCTAssertEqual(matrix.recall, 1, accuracy: accuracy)
        XCTAssertEqual(matrix.f1, 2.0 / 3.0, accuracy: accuracy)
        XCTAssertEqual(matrix.accuracy, 0.5, accuracy: accuracy)
    }

    func testZeroDenominatorsYieldZeroRatherThanNaN() {
        let nothingFlagged = ConfusionMatrix(truePositives: 0, falsePositives: 0, trueNegatives: 3, falseNegatives: 2)
        XCTAssertEqual(nothingFlagged.precision, 0)
        XCTAssertEqual(nothingFlagged.recall, 0)
        XCTAssertEqual(nothingFlagged.f1, 0)
        XCTAssertEqual(nothingFlagged.accuracy, 0.6, accuracy: accuracy)

        let empty = ConfusionMatrix()
        XCTAssertEqual(empty.total, 0)
        XCTAssertEqual(empty.precision, 0)
        XCTAssertEqual(empty.recall, 0)
        XCTAssertEqual(empty.f1, 0)
        XCTAssertEqual(empty.accuracy, 0)
    }

    func testRecordPlacesEachOutcomeInTheRightCell() {
        var matrix = ConfusionMatrix()
        matrix.record(actual: .tampered, flagged: true)
        matrix.record(actual: .tampered, flagged: false)
        matrix.record(actual: .authentic, flagged: true)
        matrix.record(actual: .authentic, flagged: false)
        matrix.record(actual: .authentic, flagged: false)

        XCTAssertEqual(matrix, ConfusionMatrix(truePositives: 1, falsePositives: 1, trueNegatives: 2, falseNegatives: 1))
    }

    // MARK: - Thresholding

    func testScoreEqualToThresholdIsFlagged() {
        XCTAssertTrue(ThresholdClassifier.isFlagged(score: 45, threshold: 45))
        XCTAssertFalse(ThresholdClassifier.isFlagged(score: 44.999, threshold: 45))
    }

    func testMatrixFromScoresClassifiesAgainstThreshold() {
        let scores: [(label: GroundTruth, score: Double)] = [
            (.authentic, 10), (.authentic, 50), (.tampered, 50), (.tampered, 20)
        ]
        let metrics = ThresholdMetrics(scores: scores, threshold: 50)

        XCTAssertEqual(metrics.confusionMatrix, ConfusionMatrix(truePositives: 1, falsePositives: 1, trueNegatives: 1, falseNegatives: 1))
        XCTAssertEqual(metrics.precision, 0.5, accuracy: accuracy)
        XCTAssertEqual(metrics.recall, 0.5, accuracy: accuracy)
        XCTAssertEqual(metrics.f1, 0.5, accuracy: accuracy)
        XCTAssertEqual(metrics.accuracy, 0.5, accuracy: accuracy)
    }

    // MARK: - Sweep

    func testDefaultSweepRangeIncludesBothEndpoints() throws {
        let thresholds = try ThresholdSweep.thresholds(min: 0, max: 100, step: 5)
        XCTAssertEqual(thresholds.count, 21)
        XCTAssertEqual(thresholds.first, 0)
        XCTAssertEqual(thresholds.last, 100)
    }

    func testFractionalStepDoesNotDriftPastTheEndpoint() throws {
        XCTAssertEqual(try ThresholdSweep.thresholds(min: 0, max: 0.3, step: 0.1), [0, 0.1, 0.2, 0.3])
        XCTAssertEqual(try ThresholdSweep.thresholds(min: 40, max: 50, step: 3), [40, 43, 46, 49])
    }

    func testInvalidSweepRangesThrow() {
        XCTAssertThrowsError(try ThresholdSweep.thresholds(min: 0, max: 100, step: 0))
        XCTAssertThrowsError(try ThresholdSweep.thresholds(min: 0, max: 100, step: -5))
        XCTAssertThrowsError(try ThresholdSweep.thresholds(min: 60, max: 40, step: 5))
        XCTAssertThrowsError(try ThresholdSweep.thresholds(min: -10, max: 40, step: 5))
        XCTAssertThrowsError(try ThresholdSweep.thresholds(min: 0, max: 150, step: 5))
    }

    func testBestThresholdMaximizesF1() throws {
        let scores: [(label: GroundTruth, score: Double)] = [
            (.authentic, 10), (.authentic, 20), (.authentic, 30),
            (.tampered, 40), (.tampered, 60), (.tampered, 80)
        ]
        let points = ThresholdSweep.evaluate(scores, at: [0, 25, 35, 50, 90])
        let best = try XCTUnwrap(ThresholdSweep.best(of: points))

        XCTAssertEqual(best.threshold, 35)
        XCTAssertEqual(best.f1, 1)
        XCTAssertEqual(points[0].recall, 1)           // threshold 0 flags everything
        XCTAssertEqual(points[0].precision, 0.5)
        XCTAssertEqual(points[4].f1, 0)               // threshold 90 flags nothing
    }

    func testBestThresholdTiesGoToTheLowerThreshold() throws {
        let scores: [(label: GroundTruth, score: Double)] = [(.authentic, 10), (.tampered, 90)]
        let points = ThresholdSweep.evaluate(scores, at: [70, 20, 50])
        XCTAssertEqual(try XCTUnwrap(ThresholdSweep.best(of: points)).threshold, 20)
        XCTAssertNil(ThresholdSweep.best(of: []))
    }
}
