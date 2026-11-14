import XCTest
import ImageDecoding
@testable import ForensicLens

/// End-to-end tests for `AIGeneratedImageAnalyzer`: both signals measured
/// on synthetic "likely fake" and "likely real" images, combined under the
/// documented rule, and reported as signals rather than verdicts.
final class AIGeneratedImageAnalyzerTests: XCTestCase {
    private func analyze(_ buffer: PixelBuffer, singleSignalWeight: Double? = nil) throws -> AnalyzerFinding {
        var config = ForensicLensConfig.default
        if let singleSignalWeight { config.aiGenerated.singleSignalWeight = singleSignalWeight }
        return try AIGeneratedImageAnalyzer().analyze(Fixtures.imageData(buffer), config: config)
    }

    // MARK: - Likely fake vs. likely real

    func testLikelyGeneratedImageScoresTheMaximumUnderTheDefaultRule() throws {
        let finding = try analyze(Fixtures.likelyGeneratedImage())
        XCTAssertEqual(finding.analyzerID, "aigenerated")
        XCTAssertEqual(finding.score, AIGenerationScore.maximumFindingScore, accuracy: 1e-9)
        XCTAssertTrue(finding.summary.hasPrefix("Signals consistent with AI generation"), finding.summary)
        XCTAssertTrue(finding.summary.contains("not a determination"), finding.summary)
        XCTAssertEqual(finding.indicators.count, 2)
        XCTAssertTrue(finding.indicators.allSatisfy { $0.weight > 0 })
        XCTAssertEqual(finding.indicators.first?.regions, [Region(x: 0, y: 0, width: 256, height: 256)], "the analyzed crop is reported")
    }

    func testLikelyCameraImageScoresZero() throws {
        let finding = try analyze(Fixtures.likelyCameraImage())
        XCTAssertEqual(finding.score, 0)
        XCTAssertTrue(finding.summary.hasPrefix("No signals consistent with AI generation"), finding.summary)
        XCTAssertTrue(finding.indicators.allSatisfy { $0.weight == 0 })
    }

    func testFakeScoresAboveRealUnderEveryWeight() throws {
        let fake = try Fixtures.likelyGeneratedImage()
        let real = try Fixtures.likelyCameraImage()
        for weight in [0.0, 0.25, 0.5, 1] {
            XCTAssertGreaterThan(try analyze(fake, singleSignalWeight: weight).score, try analyze(real, singleSignalWeight: weight).score)
        }
    }

    // MARK: - One signal on its own

    func testSpectralArtifactsAloneOnACameraImageDoNotScoreByDefault() throws {
        // A camera image carrying a periodic grid (as JPEG blocking or
        // demosaicing might leave): spectral signal yes, PRNU absence no.
        let buffer = try Fixtures.addingUpsamplingPattern(to: Fixtures.likelyCameraImage(), checkerboard: 1.5, period4: 1)
        let byDefault = try analyze(buffer)
        XCTAssertEqual(byDefault.score, 0)
        XCTAssertTrue(byDefault.summary.contains("only spectral upsampling artifacts"), byDefault.summary)

        let either = try analyze(buffer, singleSignalWeight: 1)
        XCTAssertEqual(either.score, 75, accuracy: 1e-9)
        let average = try analyze(buffer, singleSignalWeight: 0.5)
        XCTAssertEqual(average.score, 37.5, accuracy: 1e-9)
    }

    func testMissingSensorNoiseAloneDoesNotScoreByDefault() throws {
        // A clean render with no periodic pattern: no sensor noise, but no
        // spectral peaks either. Screenshots and graphics look like this.
        let buffer = try Fixtures.noiseFreeRender()
        let byDefault = try analyze(buffer)
        XCTAssertEqual(byDefault.score, 0)
        XCTAssertTrue(byDefault.summary.contains("only an absence of camera sensor noise"), byDefault.summary)

        XCTAssertEqual(try analyze(buffer, singleSignalWeight: 1).score, 75, accuracy: 1e-9)
        XCTAssertEqual(try analyze(buffer, singleSignalWeight: 0.25).score, 18.75, accuracy: 1e-9)
    }

    func testDisablingTheAbsenceSignalLeavesOnlyTheSpectralOne() throws {
        var config = ForensicLensConfig.default
        config.aiGenerated.prnuAbsenceThreshold = 0
        let finding = try AIGeneratedImageAnalyzer().analyze(Fixtures.imageData(Fixtures.likelyGeneratedImage()), config: config)
        XCTAssertEqual(finding.score, 0, "with both required, turning one off turns the check off")
        config.aiGenerated.singleSignalWeight = 1
        let either = try AIGeneratedImageAnalyzer().analyze(Fixtures.imageData(Fixtures.likelyGeneratedImage()), config: config)
        XCTAssertEqual(either.score, 75, accuracy: 1e-9)
    }

    // MARK: - Pipeline integration

    func testEngineFeedsTheFindingIntoTheSuspicionScore() throws {
        let image = try Fixtures.imageData(Fixtures.likelyGeneratedImage())
        let report = ForensicLensEngine().run(on: image)
        let finding = try XCTUnwrap(report.findings.first { $0.analyzerID == "aigenerated" })
        XCTAssertEqual(finding.score, 75, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(report.overallScore, finding.score)
        XCTAssertEqual(report.verdict, "likely manipulated")
        XCTAssertTrue(report.textReport.contains("[aigenerated] score 75/100"), report.textReport)
    }

    func testEngineLeavesACameraImageUnaffected() throws {
        let image = try Fixtures.imageData(Fixtures.likelyCameraImage())
        let report = ForensicLensEngine().run(on: image, only: ["aigenerated"])
        XCTAssertEqual(report.findings.map(\.analyzerID), ["aigenerated"])
        XCTAssertEqual(report.overallScore, 0)
    }

    func testDisabledInConfigSkipsTheAnalyzer() throws {
        var config = ForensicLensConfig.default
        config.aiGenerated.enabled = false
        let engine = ForensicLensEngine(config: config)
        let report = engine.run(on: try Fixtures.imageData(Fixtures.likelyGeneratedImage()))
        XCTAssertFalse(report.findings.contains { $0.analyzerID == "aigenerated" })
        XCTAssertTrue(engine.availableAnalyzerIDs.contains("aigenerated"))
    }

    func testTilingDoesNotChangeTheResult() throws {
        let image = try Fixtures.imageData(Fixtures.likelyGeneratedImage())
        let engine = ForensicLensEngine()
        let untiled = engine.run(on: image, only: ["aigenerated"], tiling: TilingOverride(disableTiling: true))
        let tiled = engine.run(on: image, only: ["aigenerated"], tiling: TilingOverride(forcedTileSize: 64))
        XCTAssertEqual(untiled.findings, tiled.findings)
    }

    // MARK: - Degenerate input

    func testTinyImageGivesALowConfidenceResultInsteadOfCrashing() throws {
        for (width, height) in [(1, 1), (8, 8), (40, 300)] {
            let buffer = try PixelBuffer(width: width, height: height, channels: 3, pixels: [UInt8](repeating: 128, count: width * height * 3))
            let finding = try analyze(buffer, singleSignalWeight: 1)
            XCTAssertEqual(finding.score, 0, "\(width)x\(height)")
            XCTAssertTrue(finding.summary.hasPrefix("Not assessed (low confidence)"), finding.summary)
            XCTAssertTrue(finding.indicators.allSatisfy { $0.weight == 0 })
        }
    }

    func testFlatImageNeverScores() throws {
        let flat = try PixelBuffer(width: 256, height: 256, channels: 1, pixels: [UInt8](repeating: 77, count: 256 * 256))
        XCTAssertEqual(try analyze(flat, singleSignalWeight: 0).score, 0)
    }

    func testImageWithoutPixelsIsUnsupported() throws {
        let image = try ImageData.load(Fixtures.jpegBytesWithNoExif())
        XCTAssertNil(image.pixels)
        XCTAssertThrowsError(try AIGeneratedImageAnalyzer().analyze(image, config: .default)) { error in
            guard case .unsupportedInput = error as? AnalyzerError else {
                return XCTFail("expected unsupportedInput, got \(error)")
            }
        }
    }

    // MARK: - Wording

    func testWordingNeverClaimsACertainVerdict() throws {
        let buffers = [try Fixtures.likelyGeneratedImage(), try Fixtures.likelyCameraImage(), try Fixtures.noiseFreeRender()]
        for buffer in buffers {
            for weight in [0.0, 1] {
                let finding = try analyze(buffer, singleSignalWeight: weight)
                let text = ([finding.summary] + finding.indicators.map(\.message)).joined(separator: " ").lowercased()
                for claim in ["is ai-generated", "was generated by", "is fake", "is real", "definitely", "proves"] {
                    XCTAssertFalse(text.contains(claim), "\"\(claim)\" in: \(text)")
                }
            }
        }
    }
}
