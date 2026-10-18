import XCTest
import ImageDecoding
@testable import ForensicLens

/// End-to-end coverage of CFA consistency analysis on synthetic Bayer
/// captures (see `CFAFixtures.swift`): a block without the demosaicing
/// pattern, or with it on a shifted grid, must be exactly the block
/// flagged. An untouched capture, an image with no pattern anywhere, a
/// grayscale, flat, or tiny image must produce no false finding and no crash.
final class CFAAnalyzerTests: XCTestCase {
    private let size = 256
    private let sceneSeed = 2
    /// One 64px block (the default block size), aligned to the block grid.
    private let spliceRegion = Region(x: 128, y: 64, width: 64, height: 64)

    private func capture() throws -> PixelBuffer {
        try Fixtures.demosaicedCapture(width: size, height: size, sceneSeed: sceneSeed, noiseSeed: 5)
    }

    private func spliced(_ source: Fixtures.CFASpliceSource) throws -> PixelBuffer {
        try Fixtures.splicingCFA(source, at: spliceRegion.x, spliceRegion.y, size: spliceRegion.width, into: capture())
    }

    private func consistencyMap(_ buffer: PixelBuffer, settings: ForensicLensConfig.CFAConfig = .default) throws -> CFAConsistencyMap {
        try XCTUnwrap(CFAAnalyzer.consistencyMap(for: buffer, settings: settings))
    }

    // MARK: - Genuine capture

    func testUntouchedCaptureIsConsistentEverywhere() throws {
        let buffer = try capture()
        let map = try consistencyMap(buffer)
        XCTAssertTrue(map.tracePresent)
        XCTAssertGreaterThan(map.imageStrength, 1)
        XCTAssertEqual(map.reliableBlocks.count, 16)
        XCTAssertTrue(map.inconsistentBlocks.isEmpty)
        for block in map.blocks {
            XCTAssertGreaterThan(block.consistency ?? 0, 0.8, "block at (\(block.region.x),\(block.region.y))")
        }

        let finding = try CFAAnalyzer().analyze(Fixtures.imageData(from: buffer), config: .default)
        XCTAssertEqual(finding.analyzerID, "cfa")
        XCTAssertEqual(finding.score, 0)
        XCTAssertTrue(finding.indicators.isEmpty)
        XCTAssertTrue(finding.summary.contains("consistent across all 16"), finding.summary)
    }

    // MARK: - Spliced blocks

    func testRandomPixelBlockIsFlagged() throws {
        let buffer = try spliced(.randomPixels(seed: 99))
        XCTAssertEqual(try consistencyMap(buffer).inconsistentBlocks.map(\.region), [spliceRegion])

        let finding = try CFAAnalyzer().analyze(Fixtures.imageData(from: buffer), config: .default)
        XCTAssertGreaterThan(finding.score, 45)
        XCTAssertEqual(finding.indicators.first?.regions, [spliceRegion])
        let blockIndicator = try XCTUnwrap(finding.indicators.dropFirst().first)
        XCTAssertEqual(blockIndicator.regions, [spliceRegion])
        XCTAssertTrue(blockIndicator.message.contains("missing or much weaker"), blockIndicator.message)
    }

    func testBlockRenderedWithoutAMosaicIsFlagged() throws {
        // Plausible content and sensor-like noise, but never demosaiced:
        // what a rendered, generated, or pasted-from-elsewhere patch looks like.
        let buffer = try spliced(.withoutMosaic(sceneSeed: sceneSeed, seed: 99))
        XCTAssertEqual(try consistencyMap(buffer).inconsistentBlocks.map(\.region), [spliceRegion])
    }

    func testUpsampledBlockIsFlagged() throws {
        let buffer = try spliced(.nearestUpsampled)
        XCTAssertEqual(try consistencyMap(buffer).inconsistentBlocks.map(\.region), [spliceRegion])
    }

    func testBlockOnAShiftedBayerGridIsFlaggedAsShifted() throws {
        let otherCamera = try Fixtures.demosaicedCapture(width: size, height: size, sceneSeed: sceneSeed, noiseSeed: 6, offsetX: 1)
        let buffer = try spliced(.otherCapture(otherCamera))
        let map = try consistencyMap(buffer)
        XCTAssertEqual(map.inconsistentBlocks.map(\.region), [spliceRegion])
        let block = try XCTUnwrap(map.inconsistentBlocks.first)
        XCTAssertTrue(block.latticeShifted)
        XCTAssertLessThan(block.consistency ?? 0, 0, "a pattern on the opposite lattice reads as negative")

        let finding = try CFAAnalyzer().analyze(Fixtures.imageData(from: buffer), config: .default)
        XCTAssertTrue(finding.indicators.contains { $0.message.contains("opposite lattice phase") })
    }

    func testEngineReportsTheSplicedRegion() throws {
        let image = try Fixtures.imageData(from: spliced(.randomPixels(seed: 99)))
        let report = ForensicLensEngine(config: .default).run(on: image)
        let finding = try XCTUnwrap(report.findings.first { $0.analyzerID == "cfa" })
        XCTAssertGreaterThan(finding.score, 0)
        XCTAssertTrue(finding.indicators.flatMap(\.regions).contains(spliceRegion))
        XCTAssertGreaterThanOrEqual(report.overallScore, finding.score)
    }

    func testVeryLowThresholdFlagsNothing() throws {
        var settings = ForensicLensConfig.CFAConfig.default
        settings.consistencyThreshold = -1
        XCTAssertEqual(try consistencyMap(spliced(.randomPixels(seed: 99)), settings: settings).inconsistentBlocks, [])
    }

    // MARK: - Images without a usable trace

    func testImageWithNoMosaicAnywhereIsNotAssessed() throws {
        let buffer = try Fixtures.renderedWithoutMosaic(size: size, sceneSeed: sceneSeed, seed: 99)
        let map = try consistencyMap(buffer)
        XCTAssertFalse(map.tracePresent)
        XCTAssertTrue(map.blocks.allSatisfy { $0.status == .unreliable })

        let finding = try CFAAnalyzer().analyze(Fixtures.imageData(from: buffer), config: .default)
        XCTAssertEqual(finding.score, 0)
        XCTAssertTrue(finding.summary.contains("No consistent CFA demosaicing pattern"), finding.summary)
    }

    func testRandomNoiseImageIsNotAssessed() throws {
        let image = try Fixtures.imageData(from: Fixtures.noiseBuffer(width: size, height: size, seed: 4))
        let finding = try CFAAnalyzer().analyze(image, config: .default)
        XCTAssertEqual(finding.score, 0)
        XCTAssertTrue(finding.summary.contains("No consistent CFA demosaicing pattern"), finding.summary)
    }

    func testFlatImageIsNotAssessed() throws {
        let image = try Fixtures.imageData(from: Fixtures.uniformBuffer(width: size, height: size))
        let finding = try CFAAnalyzer().analyze(image, config: .default)
        XCTAssertEqual(finding.score, 0)
        XCTAssertTrue(finding.summary.contains("Only 0 of 16"), finding.summary)
    }

    func testGrayscaleImageIsNotApplicable() throws {
        let image = try Fixtures.imageData(from: Fixtures.noiseBuffer(width: size, height: size, channels: 1))
        XCTAssertNil(CFAAnalyzer.consistencyMap(for: try XCTUnwrap(image.pixels), settings: .default))
        let finding = try CFAAnalyzer().analyze(image, config: .default)
        XCTAssertEqual(finding.score, 0)
        XCTAssertTrue(finding.summary.contains("not applicable"), finding.summary)
    }

    func testImageTooSmallForFourBlocksIsNotAssessed() throws {
        let image = try Fixtures.imageData(from: Fixtures.demosaicedCapture(width: 100, height: 100, sceneSeed: 1, noiseSeed: 1))
        let finding = try CFAAnalyzer().analyze(image, config: .default)
        XCTAssertEqual(finding.score, 0)
        XCTAssertTrue(finding.summary.contains("too small"), finding.summary)
    }

    func testImageWithoutDecodedPixelsThrowsUnsupportedInput() throws {
        let image = try ImageData.load(Fixtures.jpegBytesWithNoExif())
        XCTAssertThrowsError(try CFAAnalyzer().analyze(image, config: .default)) { error in
            guard case AnalyzerError.unsupportedInput = error else {
                return XCTFail("expected unsupportedInput, got \(error)")
            }
        }
    }

    func testBlockSizeIsRaisedToAnEvenMinimum() {
        XCTAssertEqual(CFAAnalyzer.effectiveBlockSize(4), 16)
        XCTAssertEqual(CFAAnalyzer.effectiveBlockSize(17), 18, "odd sizes would put blocks on alternating lattice phases")
        XCTAssertEqual(CFAAnalyzer.effectiveBlockSize(64), 64)
    }

    // MARK: - Pipeline integration

    func testDisabledAnalyzerDoesNotRun() throws {
        var config = ForensicLensConfig.default
        config.cfa.enabled = false
        let report = ForensicLensEngine(config: config).run(on: try Fixtures.imageData(from: capture()))
        XCTAssertFalse(report.findings.contains { $0.analyzerID == "cfa" })
        XCTAssertTrue(ForensicLensEngine(config: config).availableAnalyzerIDs.contains("cfa"))
    }

    func testTilingNeverSplitsCFAAnalysis() throws {
        let image = try Fixtures.imageData(from: spliced(.randomPixels(seed: 99)))
        let engine = ForensicLensEngine(config: .default)
        let untiled = engine.run(on: image, only: ["cfa"], tiling: TilingOverride(disableTiling: true))
        let tiled = engine.run(on: image, only: ["cfa"], tiling: TilingOverride(forcedTileSize: 64))
        XCTAssertEqual(untiled.findings, tiled.findings)
        XCTAssertGreaterThan(tiled.overallScore, 0)
    }
}
