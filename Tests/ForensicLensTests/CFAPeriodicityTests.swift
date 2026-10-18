import XCTest
@testable import ForensicLens

/// Covers the CFA periodicity math on its own: the 4-neighbor predictor,
/// lattice phases, per-phase energies, the signed strength statistic, and
/// phase voting. The inputs are small synthetic grids built with a known
/// interpolation pattern (which must score high) or as random noise (which
/// must score near zero).
final class CFAPeriodicityTests: XCTestCase {
    private let size = 34

    private func nextByte(_ generator: inout Fixtures.SeededGenerator) -> Double {
        Double(generator.nextByte())
    }

    /// Green-like: random "recorded" values on the {0, 3} quincunx, and
    /// every other interior site set to the mean of its four neighbors, as
    /// bilinear demosaicing would.
    private func greenPattern() -> PRNUPlane {
        var generator = Fixtures.SeededGenerator(seed: 21)
        var plane = PRNUPlane(width: size, height: size)
        for y in 0..<size {
            for x in 0..<size where [0, 3].contains(CFAPeriodicity.phase(x: x, y: y)) {
                plane[x, y] = nextByte(&generator)
            }
        }
        for y in 0..<size {
            for x in 0..<size where [1, 2].contains(CFAPeriodicity.phase(x: x, y: y)) {
                let interior = x > 0 && y > 0 && x < size - 1 && y < size - 1
                plane[x, y] = interior ? 0.25 * (plane[x - 1, y] + plane[x + 1, y] + plane[x, y - 1] + plane[x, y + 1]) : 128
            }
        }
        return plane
    }

    /// Red-like: random values recorded at phase 0 only, interpolated
    /// horizontally (phase 1), vertically (phase 2), and diagonally (phase 3).
    private func redPattern() -> PRNUPlane {
        var generator = Fixtures.SeededGenerator(seed: 22)
        var plane = PRNUPlane(width: size, height: size)
        for y in stride(from: 0, to: size, by: 2) {
            for x in stride(from: 0, to: size, by: 2) {
                plane[x, y] = nextByte(&generator)
            }
        }
        for y in 0..<size {
            for x in 0..<size {
                switch CFAPeriodicity.phase(x: x, y: y) {
                case 1: plane[x, y] = x + 1 < size ? 0.5 * (plane[x - 1, y] + plane[x + 1, y]) : 128
                case 2: plane[x, y] = y + 1 < size ? 0.5 * (plane[x, y - 1] + plane[x, y + 1]) : 128
                default: break
                }
            }
        }
        for y in 0..<size {
            for x in 0..<size where CFAPeriodicity.phase(x: x, y: y) == 3 {
                plane[x, y] = x + 1 < size && y + 1 < size
                    ? 0.25 * (plane[x - 1, y - 1] + plane[x + 1, y - 1] + plane[x - 1, y + 1] + plane[x + 1, y + 1])
                    : 128
            }
        }
        return plane
    }

    private func measuredEnergies(_ tile: PRNUPlane, origin: (x: Int, y: Int) = (0, 0)) throws -> [Double] {
        // Errors start one pixel in from the tile's corner.
        try XCTUnwrap(CFAPeriodicity.phaseEnergies(of: CFAPeriodicity.predictionErrors(of: tile), origin: (origin.x + 1, origin.y + 1)))
    }

    // MARK: - Predictor and phases

    func testPredictionErrorIsValueMinusFourNeighborMean() {
        let tile = PRNUPlane(width: 3, height: 3, values: [1, 2, 3, 4, 10, 6, 7, 8, 9])
        let errors = CFAPeriodicity.predictionErrors(of: tile)
        XCTAssertEqual(errors.width, 1)
        XCTAssertEqual(errors.height, 1)
        XCTAssertEqual(errors.values, [5]) // 10 - (2 + 4 + 6 + 8) / 4
        XCTAssertEqual(CFAPeriodicity.predictionErrors(of: PRNUPlane(width: 2, height: 5)).values, [])
    }

    func testPhaseIndexing() {
        XCTAssertEqual(CFAPeriodicity.phase(x: 0, y: 0), 0)
        XCTAssertEqual(CFAPeriodicity.phase(x: 1, y: 0), 1)
        XCTAssertEqual(CFAPeriodicity.phase(x: 0, y: 1), 2)
        XCTAssertEqual(CFAPeriodicity.phase(x: 1, y: 1), 3)
        XCTAssertEqual(CFAPeriodicity.phase(x: 7, y: 4), 1)
    }

    // MARK: - Strength

    func testStrengthKnownValues() {
        XCTAssertEqual(CFAPeriodicity.strength([4, 1, 1, 4], recorded: [0, 3]), log(4), accuracy: 1e-12)
        XCTAssertEqual(CFAPeriodicity.strength([4, 1, 1, 4], recorded: [1, 2]), -log(4), accuracy: 1e-12)
        XCTAssertEqual(CFAPeriodicity.strength([8, 2, 2, 2], recorded: [0]), log(4), accuracy: 1e-12)
        // Both sides at the floor: no contrast, not infinity.
        XCTAssertEqual(CFAPeriodicity.strength([0, 0, 0, 0], recorded: [0, 3]), 0)
        XCTAssertEqual(CFAPeriodicity.strength([1, 2], recorded: [0]), 0, "needs four phases")
        XCTAssertEqual(CFAPeriodicity.strength([1, 2, 3, 4], recorded: []), 0)
        XCTAssertEqual(CFAPeriodicity.strength([1, 2, 3, 4], recorded: [0, 1, 2, 3]), 0)
    }

    func testInterpolatedGreenPatternScoresHighOnItsQuincunx() throws {
        let energies = try measuredEnergies(greenPattern())
        XCTAssertGreaterThan(energies[0], 100)
        XCTAssertGreaterThan(energies[3], 100)
        XCTAssertEqual(energies[1], 0, accuracy: 1e-9, "interpolated sites are predicted exactly")
        XCTAssertEqual(energies[2], 0, accuracy: 1e-9)

        XCTAssertEqual(CFAPeriodicity.dominantQuincunx(CFAPeriodicity.phaseVotes([energies])), [0, 3])
        XCTAssertGreaterThan(CFAPeriodicity.strength(energies, recorded: [0, 3]), 5)
        XCTAssertLessThan(CFAPeriodicity.strength(energies, recorded: [1, 2]), -5, "the opposite quincunx reads as a shifted lattice")
    }

    func testPhasesFollowAbsolutePositionNotTilePosition() throws {
        // The same tile, located one pixel to the right in the image: its
        // recorded sites now fall on the other quincunx.
        let shifted = try measuredEnergies(greenPattern(), origin: (1, 0))
        XCTAssertEqual(CFAPeriodicity.dominantQuincunx(CFAPeriodicity.phaseVotes([shifted])), [1, 2])
    }

    func testInterpolatedRedPatternScoresHighOnItsPhase() throws {
        let energies = try measuredEnergies(redPattern())
        XCTAssertEqual(CFAPeriodicity.dominantPhase(CFAPeriodicity.phaseVotes([energies])), 0)
        XCTAssertGreaterThan(CFAPeriodicity.strength(energies, recorded: [0]), 1.5)
    }

    func testRandomNoiseHasNoPeriodicity() throws {
        var generator = Fixtures.SeededGenerator(seed: 23)
        let noise = PRNUPlane(width: 66, height: 66, values: (0..<(66 * 66)).map { _ in nextByte(&generator) })
        let energies = try measuredEnergies(noise)
        XCTAssertLessThan(abs(CFAPeriodicity.strength(energies, recorded: [0, 3])), 0.15)
        for phase in 0..<4 {
            XCTAssertLessThan(abs(CFAPeriodicity.strength(energies, recorded: [phase])), 0.15, "phase \(phase)")
        }
    }

    func testFlatTileHasNoEnergyAndNoContrast() throws {
        let energies = try measuredEnergies(PRNUPlane(width: 20, height: 20, repeating: 90))
        XCTAssertEqual(energies, [0, 0, 0, 0])
        XCTAssertEqual(CFAPeriodicity.strength(energies, recorded: [0, 3]), 0)
    }

    func testTooFewSamplesPerPhaseIsNil() {
        let errors = CFAPeriodicity.predictionErrors(of: PRNUPlane(width: 6, height: 6, repeating: 1))
        XCTAssertNil(CFAPeriodicity.phaseEnergies(of: errors, origin: (1, 1)), "a 4x4 error grid has 4 samples per phase")
    }

    // MARK: - Phase voting

    func testPhaseVotesNormalizePerBlock() {
        let votes = CFAPeriodicity.phaseVotes([[3, 1, 0, 0], [0, 0, 0, 0], [1, 1, 1, 1]])
        XCTAssertEqual(votes, [1.0, 0.5, 0.25, 0.25])
        XCTAssertEqual(CFAPeriodicity.dominantPhase(votes), 0)
        XCTAssertEqual(CFAPeriodicity.dominantQuincunx(votes), [0, 3])
    }

    func testOneHighEnergyBlockCannotOutvoteTheRest() {
        // A patch of random pixels has huge, nearly uniform energy; three
        // ordinary blocks recorded at phase 0 must still win.
        let blocks: [[Double]] = [[1000, 1000, 1000, 1001], [4, 1, 1, 1], [4, 1, 1, 1], [4, 1, 1, 1]]
        XCTAssertEqual(CFAPeriodicity.dominantPhase(CFAPeriodicity.phaseVotes(blocks)), 0)
    }
}
