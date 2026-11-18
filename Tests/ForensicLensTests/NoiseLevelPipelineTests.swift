import XCTest
import ImageDecoding
@testable import ForensicLens

/// The noise-level check inside the full pipeline: selected and skipped
/// like every other analyzer, never split by tiling, and scored by
/// `SuspicionScorer` the same way.
final class NoiseLevelPipelineTests: XCTestCase {
    private let smoothRegion = Region(x: 128, y: 64, width: 64, height: 64)

    private func splicedImage() throws -> ImageData {
        try Fixtures.imageData(from: Fixtures.noiseLevelImage(width: 320, height: 320, sigma: 3, splices: [
            (smoothRegion, .blurred(radius: 2)),
        ]))
    }

    func testEngineRunsItAlone() throws {
        let report = ForensicLensEngine().run(on: try splicedImage(), only: ["noiselevel"])
        XCTAssertEqual(report.findings.map(\.analyzerID), ["noiselevel"])
        let finding = try XCTUnwrap(report.findings.first)
        XCTAssertGreaterThan(finding.score, 0)
        XCTAssertEqual(report.overallScore, finding.score, accuracy: 1e-9, "a lone finding is the overall score")
        XCTAssertEqual(Set(finding.indicators.flatMap(\.regions)), [smoothRegion])
    }

    func testItIsPartOfTheFullReport() throws {
        let engine = ForensicLensEngine()
        XCTAssertEqual(engine.availableAnalyzerIDs.last, "noiselevel")
        let report = engine.run(on: try splicedImage())
        XCTAssertTrue(report.findings.contains { $0.analyzerID == "noiselevel" && $0.score > 0 })
    }

    func testDisabledInConfigSkipsTheAnalyzer() throws {
        var config = ForensicLensConfig.default
        config.noiseLevel.enabled = false
        let engine = ForensicLensEngine(config: config)
        let report = engine.run(on: try splicedImage())
        XCTAssertFalse(report.findings.contains { $0.analyzerID == "noiselevel" })
        XCTAssertTrue(engine.availableAnalyzerIDs.contains("noiselevel"))
    }

    func testItCanRunAloneWithEveryHeavierDetectorDisabled() throws {
        // The fast pre-check use: everything expensive off, this one on.
        var config = ForensicLensConfig.default
        config.prnu.enabled = false
        config.cfa.enabled = false
        config.cloneDetection.enabled = false
        config.jpegGhost.enabled = false
        config.ela.enabled = false
        config.doubleCompression.enabled = false
        config.aiGenerated.enabled = false
        let report = ForensicLensEngine(config: config).run(on: try splicedImage())
        XCTAssertEqual(Set(report.findings.map(\.analyzerID)), ["metadata", "thumbnail", "noiselevel"])
        XCTAssertGreaterThan(report.overallScore, 0)
    }

    func testTilingNeverSplitsTheNoiseLevelCheck() throws {
        let image = try splicedImage()
        let engine = ForensicLensEngine()
        let untiled = engine.run(on: image, only: ["noiselevel"], tiling: TilingOverride(disableTiling: true))
        let tiled = engine.run(on: image, only: ["noiselevel"], tiling: TilingOverride(forcedTileSize: 64))
        XCTAssertEqual(untiled.findings, tiled.findings)
        XCTAssertGreaterThan(tiled.overallScore, 0)
    }

    func testScorerCombinesItLikeAnyOtherFinding() {
        let noise = AnalyzerFinding(analyzerID: "noiselevel", score: 40, summary: "", indicators: [])
        let prnu = AnalyzerFinding(analyzerID: "prnu", score: 60, summary: "", indicators: [])
        let report = SuspicionScorer().score([prnu, noise])
        // The strongest finding dominates; the noise-level check corroborates.
        XCTAssertEqual(report.overallScore, 60 + 40 * 0.15, accuracy: 1e-9)
    }
}
