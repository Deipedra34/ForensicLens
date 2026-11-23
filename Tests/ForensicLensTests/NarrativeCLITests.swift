import XCTest
import ImageDecoding
@testable import ForensicLens
@testable import forensiclens_cli

/// The `--narrative brief|full|off` option, which the single-image commands
/// and `batch` apply on top of the loaded config.
final class NarrativeCLITests: XCTestCase {
    private func parsed(_ options: [String: String] = [:], flags: Set<String> = []) -> CLI.ParsedArguments {
        CLI.ParsedArguments(positionals: ["photo.ppm"], flags: flags, options: options)
    }

    func testOptionSetsTheVerbosityOrTurnsTheNarrativeOff() throws {
        let full = try CLI.applyingNarrativeOption(parsed(["--narrative": "full"]), to: .default)
        XCTAssertTrue(full.report.narrative)
        XCTAssertEqual(full.report.narrativeVerbosity, .full)

        let brief = try CLI.applyingNarrativeOption(parsed(["--narrative": "BRIEF"]), to: .default)
        XCTAssertEqual(brief.report.narrativeVerbosity, .brief)

        let off = try CLI.applyingNarrativeOption(parsed(["--narrative": "off"]), to: .default)
        XCTAssertFalse(off.report.narrative)

        var expected = ForensicLensConfig.default
        expected.report.narrative = false
        XCTAssertEqual(off, expected, "nothing else in the config changes")
    }

    func testOptionCanTurnANarrativeTheConfigDisabledBackOn() throws {
        var fromFile = ForensicLensConfig.default
        fromFile.report.narrative = false
        let config = try CLI.applyingNarrativeOption(parsed(["--narrative": "brief"]), to: fromFile)
        XCTAssertTrue(config.report.narrative)
    }

    func testWithoutTheOptionTheConfigIsUnchanged() throws {
        var fromFile = ForensicLensConfig.default
        fromFile.report.narrativeVerbosity = .full
        XCTAssertEqual(try CLI.applyingNarrativeOption(parsed(), to: fromFile), fromFile)
    }

    func testInvalidOrMissingValuesAreErrors() {
        XCTAssertThrowsError(try CLI.applyingNarrativeOption(parsed(["--narrative": "verbose"]), to: .default)) { error in
            XCTAssertTrue("\(error)".contains("brief, full, or off"), "\(error)")
        }
        XCTAssertThrowsError(try CLI.applyingNarrativeOption(parsed(flags: ["--narrative"]), to: .default)) { error in
            XCTAssertTrue("\(error)".contains("requires a value"), "\(error)")
        }
    }

    func testCommandsAcceptTheOptionAndRejectBadValues() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("forensiclens-narrative-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let imagePath = root.appendingPathComponent("photo.ppm").path
        try Data(ImageEncoder.encodePPM(Fixtures.noiseBuffer(width: 64, height: 64, seed: 2))).write(to: URL(fileURLWithPath: imagePath))
        let config = root.appendingPathComponent("missing.yaml").path

        for value in ["brief", "full", "off"] {
            let exitCode = await CLI.run(arguments: ["forensiclens-cli", "clone", imagePath, "--narrative", value, "--config", config])
            XCTAssertEqual(exitCode, 0, value)
        }
        let rejected = await CLI.run(arguments: ["forensiclens-cli", "clone", imagePath, "--narrative", "chatty", "--config", config])
        XCTAssertEqual(rejected, 1)
        let batch = await CLI.run(arguments: ["forensiclens-cli", "batch", root.path, "--extensions", "ppm", "--narrative", "off", "--config", config])
        XCTAssertEqual(batch, 0)
    }
}
