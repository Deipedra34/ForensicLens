import XCTest
@testable import ForensicLens

/// Covers the combination rule on its own: `likelihood = min + w * (max - min)`
/// over the spectral and PRNU-absence signals, and its mapping to a
/// finding score.
final class AIGenerationScoreTests: XCTestCase {
    private func likelihood(_ s: Double, _ a: Double, weight: Double) -> Double {
        AIGenerationScore.likelihood(spectral: s, prnuAbsence: a, singleSignalWeight: weight)
    }

    func testDefaultRuleRequiresBothSignals() {
        let w = AIGenerationScore.defaultSingleSignalWeight
        XCTAssertEqual(w, 0)
        XCTAssertEqual(likelihood(1, 1, weight: w), 1)
        XCTAssertEqual(likelihood(1, 0, weight: w), 0)
        XCTAssertEqual(likelihood(0, 1, weight: w), 0)
        XCTAssertEqual(likelihood(0.6, 0.9, weight: w), 0.6, accuracy: 1e-12)
    }

    func testWeightOfOneLetsEitherSignalDecide() {
        XCTAssertEqual(likelihood(1, 0, weight: 1), 1)
        XCTAssertEqual(likelihood(0, 0.7, weight: 1), 0.7, accuracy: 1e-12)
        XCTAssertEqual(likelihood(0.2, 0.5, weight: 1), 0.5, accuracy: 1e-12)
    }

    func testWeightOfOneHalfAverages() {
        XCTAssertEqual(likelihood(1, 0, weight: 0.5), 0.5, accuracy: 1e-12)
        XCTAssertEqual(likelihood(0.2, 0.8, weight: 0.5), 0.5, accuracy: 1e-12)
    }

    func testRuleIsSymmetricAndMonotonic() {
        for weight in [0.0, 0.25, 0.5, 1] {
            for (s, a) in [(0.1, 0.9), (0.4, 0.4), (1, 0.3)] {
                XCTAssertEqual(likelihood(s, a, weight: weight), likelihood(a, s, weight: weight), accuracy: 1e-12)
                XCTAssertLessThanOrEqual(likelihood(s, a, weight: weight), likelihood(min(1, s + 0.1), a, weight: weight) + 1e-12)
            }
            XCTAssertEqual(likelihood(0, 0, weight: weight), 0)
        }
    }

    func testInputsAreClampedAndNonFiniteValuesCountAsZero() {
        XCTAssertEqual(likelihood(5, 2, weight: 0), 1)
        XCTAssertEqual(likelihood(-1, 1, weight: 0), 0)
        XCTAssertEqual(likelihood(.nan, 1, weight: 1), 1)
        XCTAssertEqual(likelihood(.infinity, 1, weight: 0), 0)
        XCTAssertEqual(likelihood(1, 0, weight: 4), 1, "weight clamped to 1")
        XCTAssertEqual(likelihood(1, 0, weight: -2), 0, "weight clamped to 0")
    }

    func testFindingScoreIsLinearUpToSeventyFive() {
        XCTAssertEqual(AIGenerationScore.maximumFindingScore, 75)
        XCTAssertEqual(AIGenerationScore.findingScore(likelihood: 0), 0)
        XCTAssertEqual(AIGenerationScore.findingScore(likelihood: 0.5), 37.5, accuracy: 1e-12)
        XCTAssertEqual(AIGenerationScore.findingScore(likelihood: 1), 75)
        XCTAssertEqual(AIGenerationScore.findingScore(likelihood: 3), 75)
        XCTAssertEqual(AIGenerationScore.findingScore(likelihood: .nan), 0)
    }
}
