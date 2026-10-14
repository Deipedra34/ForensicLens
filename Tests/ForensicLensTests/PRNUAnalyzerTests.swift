import XCTest
import ImageDecoding
@testable import ForensicLens

/// End-to-end coverage of PRNU local consistency: synthetic sensor captures
/// (see `PRNUFixtures.swift`) with a block spliced in from a different
/// noise source must have exactly that block flagged, while an untouched
/// capture, a degenerate image, or an image too small to analyze must not
/// produce a false finding or a crash.
final class PRNUAnalyzerTests: XCTestCase {
    private let size = 256
    private let sceneSeed = 3
    /// One 64px block (the default block size), aligned to the block grid.
    private let spliceRegion = Region(x: 128, y: 64, width: 64, height: 64)

    private func capture() throws -> PixelBuffer {
        try Fixtures.simulatedCapture(
            width: size,
            height: size,
            sensor: Fixtures.sensorPattern(width: size, height: size, seed: 11),
            sceneSeed: sceneSeed,
            noiseSeed: 101
        )
    }

    private func spliced(_ source: Fixtures.SpliceSource) throws -> PixelBuffer {
        try Fixtures.splicing(source, sceneSeed: sceneSeed, at: spliceRegion.x, spliceRegion.y, size: spliceRegion.width, into: capture())
    }

    private func flaggedRegions(_ buffer: PixelBuffer, settings: ForensicLensConfig.PRNUConfig = .default) throws -> [Region] {
        let map = try XCTUnwrap(PRNUAnalyzer.consistencyMap(for: buffer, settings: settings))
        return map.inconsistentBlocks.map(\.region)
    }

    // MARK: - Consistent images

    func testUntouchedCaptureHasConsistentNoiseEverywhere() throws {
        let buffer = try capture()
        let map = try XCTUnwrap(PRNUAnalyzer.consistencyMap(for: buffer, settings: .default))
        XCTAssertEqual(map.columns, 4)
        XCTAssertEqual(map.rows, 4)
        XCTAssertEqual(map.reliableBlocks.count, 16)
        XCTAssertTrue(map.inconsistentBlocks.isEmpty)
        for block in map.blocks {
            XCTAssertGreaterThan(block.consistency ?? 0, 0.8, "block at (\(block.region.x),\(block.region.y))")
        }

        let finding = try PRNUAnalyzer().analyze(Fixtures.imageData(from: buffer), config: .default)
        XCTAssertEqual(finding.analyzerID, "prnu")
        XCTAssertEqual(finding.score, 0)
        XCTAssertTrue(finding.indicators.isEmpty)
        XCTAssertTrue(finding.summary.contains("consistent across all 16"), finding.summary)
    }

    // MARK: - Spliced regions

    func testNoiseFreeSpliceIsFlagged() throws {
        let buffer = try spliced(.noiseFree)
        XCTAssertEqual(try flaggedRegions(buffer), [spliceRegion])

        let finding = try PRNUAnalyzer().analyze(Fixtures.imageData(from: buffer), config: .default)
        XCTAssertGreaterThan(finding.score, 45, "one of 16 blocks with no sensor noise at all is a strong signal")
        let summaryIndicator = try XCTUnwrap(finding.indicators.first)
        XCTAssertEqual(summaryIndicator.regions, [spliceRegion])
        let blockIndicator = try XCTUnwrap(finding.indicators.dropFirst().first)
        XCTAssertEqual(blockIndicator.regions, [spliceRegion])
        XCTAssertTrue(blockIndicator.message.contains("almost no sensor noise"), blockIndicator.message)
    }

    func testSpliceWithDifferentlyStructuredNoiseIsFlagged() throws {
        // Similar noise *level* to the capture, but spatially correlated --
        // the signature of a region that was resampled or filtered, or came
        // through a different capture pipeline -- so only the correlation
        // structure gives it away.
        let buffer = try spliced(.smoothedNoise(radius: 2, amplitude: 3, seed: 77))
        let map = try XCTUnwrap(PRNUAnalyzer.consistencyMap(for: buffer, settings: .default))
        XCTAssertEqual(map.inconsistentBlocks.map(\.region), [spliceRegion])
        let splicedBlock = try XCTUnwrap(map.inconsistentBlocks.first)
        XCTAssertGreaterThan(splicedBlock.noiseLevelRatio ?? 0, 0.4, "the spliced noise isn't simply missing")

        let finding = try PRNUAnalyzer().analyze(Fixtures.imageData(from: buffer), config: .default)
        XCTAssertGreaterThan(finding.score, 0)
        XCTAssertEqual(finding.indicators.first?.regions, [spliceRegion])
    }

    func testEngineReportsTheSplicedRegionAndRaisesTheOverallScore() throws {
        let image = try Fixtures.imageData(from: spliced(.noiseFree))
        let report = ForensicLensEngine(config: .default).run(on: image)
        let finding = try XCTUnwrap(report.findings.first { $0.analyzerID == "prnu" })
        XCTAssertGreaterThan(finding.score, 0)
        XCTAssertTrue(finding.indicators.flatMap(\.regions).contains(spliceRegion))
        XCTAssertGreaterThanOrEqual(report.overallScore, finding.score)
    }

    func testThresholdZeroFlagsNothing() throws {
        var settings = ForensicLensConfig.PRNUConfig.default
        settings.correlationThreshold = 0
        XCTAssertEqual(try flaggedRegions(spliced(.noiseFree), settings: settings), [])
    }

    // MARK: - Working resolution

    func testWorkingResolutionCapDownsamplesAndMapsRegionsBack() throws {
        var config = ForensicLensConfig.default
        config.prnu.maximumWorkingDimension = 128
        config.prnu.blockSize = 32
        let buffer = try spliced(.noiseFree)

        // At half resolution, each 32px block covers 64px of the original.
        XCTAssertEqual(PRNUAnalyzer.workingScale(width: 256, height: 256, maximumWorkingDimension: 128), 2)
        let map = try XCTUnwrap(PRNUAnalyzer.consistencyMap(for: buffer, settings: config.prnu))
        XCTAssertEqual(map.columns, 4)
        XCTAssertEqual(map.blocks.first?.region, Region(x: 0, y: 0, width: 64, height: 64))
        XCTAssertEqual(map.inconsistentBlocks.map(\.region), [spliceRegion])

        let finding = try PRNUAnalyzer().analyze(Fixtures.imageData(from: buffer), config: config)
        XCTAssertTrue(finding.summary.contains("1/2 resolution"), finding.summary)
    }

    func testWorkingScaleFitsTheLargerSideUnderTheCap() {
        XCTAssertEqual(PRNUAnalyzer.workingScale(width: 2048, height: 1000, maximumWorkingDimension: 2048), 1)
        XCTAssertEqual(PRNUAnalyzer.workingScale(width: 2049, height: 1000, maximumWorkingDimension: 2048), 2)
        XCTAssertEqual(PRNUAnalyzer.workingScale(width: 4000, height: 6000, maximumWorkingDimension: 2048), 3)
        XCTAssertEqual(PRNUAnalyzer.workingScale(width: 500, height: 500, maximumWorkingDimension: 0), 8, "a cap under 64 is raised to 64")
    }

    // MARK: - Degenerate input

    func testUniformImageIsNotAssessedRatherThanFlagged() throws {
        let image = try Fixtures.imageData(from: Fixtures.uniformBuffer(width: size, height: size, channels: 1, value: 128))
        let finding = try PRNUAnalyzer().analyze(image, config: .default)
        XCTAssertEqual(finding.score, 0)
        XCTAssertTrue(finding.summary.contains("No measurable sensor noise"), finding.summary)
        XCTAssertTrue(finding.indicators.isEmpty)
    }

    func testClippedImageIsNotAssessed() throws {
        let image = try Fixtures.imageData(from: Fixtures.uniformBuffer(width: size, height: size, channels: 1, value: 255))
        let map = try XCTUnwrap(PRNUAnalyzer.consistencyMap(for: XCTUnwrap(image.pixels), settings: .default))
        XCTAssertTrue(map.blocks.allSatisfy { $0.status == .unreliable })

        let finding = try PRNUAnalyzer().analyze(image, config: .default)
        XCTAssertEqual(finding.score, 0)
        XCTAssertTrue(finding.summary.contains("clipped"), finding.summary)
    }

    func testImageTooSmallForFourBlocksIsNotAssessed() throws {
        let image = try Fixtures.imageData(from: Fixtures.noiseBuffer(width: 100, height: 100, channels: 1))
        XCTAssertNil(PRNUAnalyzer.consistencyMap(for: try XCTUnwrap(image.pixels), settings: .default))
        let finding = try PRNUAnalyzer().analyze(image, config: .default)
        XCTAssertEqual(finding.score, 0)
        XCTAssertTrue(finding.summary.contains("too small"), finding.summary)
    }

    func testTinyBlockSizeIsRaisedToTheMinimum() throws {
        var settings = ForensicLensConfig.PRNUConfig.default
        settings.blockSize = 2
        let map = try XCTUnwrap(PRNUAnalyzer.consistencyMap(for: capture(), settings: settings))
        XCTAssertEqual(map.columns, size / PRNUAnalyzer.minimumBlockSize)
    }

    func testImageWithoutDecodedPixelsThrowsUnsupportedInput() throws {
        let image = try ImageData.load(Fixtures.jpegBytesWithNoExif())
        XCTAssertThrowsError(try PRNUAnalyzer().analyze(image, config: .default)) { error in
            guard case AnalyzerError.unsupportedInput = error else {
                return XCTFail("expected unsupportedInput, got \(error)")
            }
        }
    }

    // MARK: - Pipeline integration

    func testDisabledAnalyzerDoesNotRun() throws {
        var config = ForensicLensConfig.default
        config.prnu.enabled = false
        let report = ForensicLensEngine(config: config).run(on: try Fixtures.imageData(from: capture()))
        XCTAssertFalse(report.findings.contains { $0.analyzerID == "prnu" })
        XCTAssertTrue(ForensicLensEngine(config: config).availableAnalyzerIDs.contains("prnu"))
    }

    func testTilingNeverSplitsPRNUAnalysis() throws {
        let image = try Fixtures.imageData(from: spliced(.noiseFree))
        let engine = ForensicLensEngine(config: .default)
        let untiled = engine.run(on: image, only: ["prnu"], tiling: TilingOverride(disableTiling: true))
        let tiled = engine.run(on: image, only: ["prnu"], tiling: TilingOverride(forcedTileSize: 64))
        XCTAssertEqual(untiled.findings, tiled.findings)
        XCTAssertGreaterThan(tiled.overallScore, 0)
    }

    func testConfiguredButUnloadedReferenceIsReportedNotIgnored() throws {
        var config = ForensicLensConfig.default
        config.prnu.referenceFolder = "some/folder"
        let finding = try PRNUAnalyzer().analyze(Fixtures.imageData(from: capture()), config: config)
        XCTAssertEqual(finding.score, 0)
        XCTAssertTrue(finding.indicators.contains { $0.message.contains("no fingerprint was loaded") })
    }
}
