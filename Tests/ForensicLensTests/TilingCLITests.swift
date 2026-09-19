import XCTest
import ForensicLens
@testable import forensiclens_cli

/// Covers the `--tile-size` / `--no-tiling` CLI flags' parsing, which both
/// the single-image commands and `batch` share via `CLI.parseTilingOverride`.
final class TilingCLITests: XCTestCase {
    func testTileSizeFlagForcesTiling() throws {
        let parsed = CLI.ParsedArguments(positionals: [], flags: [], options: ["--tile-size": "256"])
        let override = try CLI.parseTilingOverride(parsed)

        XCTAssertEqual(override.forcedTileSize, 256)
        XCTAssertFalse(override.disableTiling)
    }

    func testNoTilingFlagDisablesTiling() throws {
        let parsed = CLI.ParsedArguments(positionals: [], flags: ["--no-tiling"], options: [:])
        let override = try CLI.parseTilingOverride(parsed)

        XCTAssertTrue(override.disableTiling)
        XCTAssertNil(override.forcedTileSize)
    }

    func testNeitherFlagYieldsNoOverride() throws {
        let parsed = CLI.ParsedArguments(positionals: [], flags: [], options: [:])
        let override = try CLI.parseTilingOverride(parsed)

        XCTAssertFalse(override.disableTiling)
        XCTAssertNil(override.forcedTileSize)
    }

    func testCombiningBothFlagsThrows() {
        let parsed = CLI.ParsedArguments(positionals: [], flags: ["--no-tiling"], options: ["--tile-size": "256"])
        XCTAssertThrowsError(try CLI.parseTilingOverride(parsed)) { error in
            guard case CLIError.conflictingTilingFlags = error else {
                return XCTFail("Expected CLIError.conflictingTilingFlags, got \(error)")
            }
        }
    }

    func testNonNumericTileSizeThrows() {
        let parsed = CLI.ParsedArguments(positionals: [], flags: [], options: ["--tile-size": "banana"])
        XCTAssertThrowsError(try CLI.parseTilingOverride(parsed)) { error in
            guard case CLIError.invalidTileSize(let value) = error else {
                return XCTFail("Expected CLIError.invalidTileSize, got \(error)")
            }
            XCTAssertEqual(value, "banana")
        }
    }

    func testZeroOrNegativeTileSizeThrows() {
        for expectedValue in ["0", "-4"] {
            let parsed = CLI.ParsedArguments(positionals: [], flags: [], options: ["--tile-size": expectedValue])
            XCTAssertThrowsError(try CLI.parseTilingOverride(parsed)) { error in
                guard case CLIError.invalidTileSize(let actualValue) = error else {
                    return XCTFail("Expected CLIError.invalidTileSize, got \(error)")
                }
                XCTAssertEqual(actualValue, expectedValue)
            }
        }
    }
}
