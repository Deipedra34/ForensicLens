import XCTest
@testable import ForensicLens

/// The `report` section of `forensiclens.yaml`: narrative on/off and verbosity.
final class ReportConfigTests: XCTestCase {
    func testDefaultsGenerateABriefNarrative() {
        XCTAssertTrue(ForensicLensConfig.default.report.narrative)
        XCTAssertEqual(ForensicLensConfig.default.report.narrativeVerbosity, .brief)
        XCTAssertEqual(ForensicLensConfig.default.report, .default)
    }

    func testReportSectionIsParsed() throws {
        let config = try ConfigLoader.parse("""
        report:
          narrative: false
          narrativeVerbosity: full
        """)
        XCTAssertFalse(config.report.narrative)
        XCTAssertEqual(config.report.narrativeVerbosity, .full)
        // Everything else keeps its default.
        XCTAssertEqual(config.ela, ForensicLensConfig.default.ela)
    }

    func testVerbosityIsCaseInsensitive() throws {
        XCTAssertEqual(try ConfigLoader.parse("report:\n  narrativeVerbosity: FULL").report.narrativeVerbosity, .full)
        XCTAssertEqual(try ConfigLoader.parse("report:\n  narrativeVerbosity: Brief").report.narrativeVerbosity, .brief)
    }

    func testInvalidReportValuesAreRejected() {
        XCTAssertThrowsError(try ConfigLoader.parse("report:\n  narrativeVerbosity: chatty")) { error in
            XCTAssertEqual(error as? ConfigError, .invalidValue(key: "narrativeVerbosity", value: "chatty"))
        }
        XCTAssertThrowsError(try ConfigLoader.parse("report:\n  narrative: sometimes")) { error in
            XCTAssertEqual(error as? ConfigError, .invalidValue(key: "narrative", value: "sometimes"))
        }
        XCTAssertThrowsError(try ConfigLoader.parse("report:\n  tone: friendly")) { error in
            XCTAssertEqual(error as? ConfigError, .unknownKey(section: "report", key: "tone"))
        }
    }

    func testShippedConfigDocumentsTheReportDefaults() throws {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("forensiclens.yaml")
            .path
        XCTAssertEqual(try ConfigLoader.load(contentsOfFile: path).report, ForensicLensConfig.ReportConfig.default)
    }
}
