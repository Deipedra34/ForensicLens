import XCTest
import ForensicLens
@testable import forensiclens_cli

/// Covers the `--no-feature-matching` CLI flag, which both the single-image
/// commands and `batch` apply on top of the loaded config via
/// `CLI.applyingFeatureMatchingFlag`.
final class FeatureMatchingCLITests: XCTestCase {
    func testFlagDisablesOnlyTheFeatureMatchingPass() {
        let parsed = CLI.ParsedArguments(positionals: ["photo.ppm"], flags: ["--no-feature-matching"], options: [:])
        let config = CLI.applyingFeatureMatchingFlag(parsed, to: .default)

        XCTAssertFalse(config.cloneDetection.featureMatchingEnabled)
        XCTAssertTrue(config.cloneDetection.enabled, "block matching still runs")

        var expected = ForensicLensConfig.default
        expected.cloneDetection.featureMatchingEnabled = false
        XCTAssertEqual(config, expected, "nothing else in the config changes")
    }

    func testWithoutFlagConfigIsUnchanged() {
        let parsed = CLI.ParsedArguments(positionals: ["photo.ppm"], flags: ["--json"], options: [:])
        XCTAssertEqual(CLI.applyingFeatureMatchingFlag(parsed, to: .default), .default)
    }

    func testFlagCannotReEnableAPassTheConfigTurnedOff() {
        var fromFile = ForensicLensConfig.default
        fromFile.cloneDetection.featureMatchingEnabled = false
        let parsed = CLI.ParsedArguments(positionals: [], flags: [], options: [:])

        XCTAssertFalse(CLI.applyingFeatureMatchingFlag(parsed, to: fromFile).cloneDetection.featureMatchingEnabled)
    }
}
