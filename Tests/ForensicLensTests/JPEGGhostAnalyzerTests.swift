import XCTest
import ImageDecoding
@testable import ForensicLens

/// End-to-end coverage of JPEG ghost detection. Every JPEG here is made with
/// the same `JPEGRecompressionSimulator` the analyzers use: a host texture
/// saved at one quality, a block from another texture pre-compressed at a
/// clearly different quality spliced in on the 8x8 grid, and the composite
/// saved again. The spliced block must be exactly what's flagged. Images
/// with no JPEG history, or nothing to measure, must come back "not
/// applicable" or "not assessed", never with a score.
final class JPEGGhostAnalyzerTests: XCTestCase {
    private let size = 256
    /// Two 32px blocks square (the default block size), on the block grid.
    private let spliceRegion = Region(x: 128, y: 64, width: 64, height: 64)
    private var spliceBlocks: [Region] {
        [Region(x: 128, y: 64, width: 32, height: 32), Region(x: 160, y: 64, width: 32, height: 32),
         Region(x: 128, y: 96, width: 32, height: 32), Region(x: 160, y: 96, width: 32, height: 32)]
    }

    private func texture(seed: UInt64) throws -> PixelBuffer {
        try Fixtures.smoothTextureBuffer(width: size, height: size, seed: seed)
    }

    private func jpeg(_ buffer: PixelBuffer, quality: Int) -> PixelBuffer {
        JPEGRecompressionSimulator.recompress(buffer, quality: quality)
    }

    /// A host saved at `host`, with `spliceRegion` taken from another image
    /// saved at `splice`, then the composite saved at `final`.
    private func splicedComposite(host: Int, splice: Int, final: Int) throws -> PixelBuffer {
        let base = jpeg(try texture(seed: 7), quality: host)
        let source = jpeg(try texture(seed: 11), quality: splice)
        var pixels = base.pixels
        for row in spliceRegion.y..<(spliceRegion.y + spliceRegion.height) {
            for col in spliceRegion.x..<(spliceRegion.x + spliceRegion.width) {
                pixels[row * size + col] = source.pixels[row * size + col]
            }
        }
        return jpeg(try PixelBuffer(width: size, height: size, channels: 1, pixels: pixels), quality: final)
    }

    private func ghostMap(_ buffer: PixelBuffer, settings: ForensicLensConfig.JPEGGhostConfig = .default) throws -> JPEGGhostMap {
        try XCTUnwrap(JPEGGhostAnalyzer.ghostMap(for: buffer, settings: settings))
    }

    // MARK: - Spliced regions

    func testBlockFromALowerQualityJPEGIsFlagged() throws {
        let composite = try splicedComposite(host: 85, splice: 60, final: 85)
        let map = try ghostMap(composite)
        XCTAssertEqual(map.dominantQuality, 85)
        XCTAssertEqual(map.inconsistentBlocks.map(\.region), spliceBlocks)
        XCTAssertTrue(map.inconsistentBlocks.allSatisfy { $0.ghostQuality == 60 })

        let finding = try JPEGGhostAnalyzer().analyze(Fixtures.imageData(from: composite), config: .default)
        XCTAssertEqual(finding.analyzerID, "jpegghost")
        XCTAssertGreaterThan(finding.score, 45)
        let summaryIndicator = try XCTUnwrap(finding.indicators.first)
        XCTAssertEqual(summaryIndicator.regions, spliceBlocks)
        XCTAssertTrue(finding.indicators.dropFirst().allSatisfy { $0.message.contains("quality 60, versus 85") })
    }

    func testBlockFromAHigherQualityJPEGIsFlaggedWhenSavedAtThatQuality() throws {
        // Host originally at 70; a quality-90 patch pasted in; saved at 90.
        let map = try ghostMap(splicedComposite(host: 70, splice: 90, final: 90))
        XCTAssertEqual(map.dominantQuality, 70)
        XCTAssertEqual(map.inconsistentBlocks.map(\.region), spliceBlocks)
        XCTAssertTrue(map.inconsistentBlocks.allSatisfy { $0.ghostQuality == 90 })
    }

    func testEngineReportsTheSplicedBlocks() throws {
        let image = try Fixtures.imageData(from: splicedComposite(host: 85, splice: 60, final: 85))
        let report = ForensicLensEngine(config: .default).run(on: image)
        let finding = try XCTUnwrap(report.findings.first { $0.analyzerID == "jpegghost" })
        XCTAssertGreaterThan(finding.score, 0)
        XCTAssertEqual(Set(finding.indicators.flatMap(\.regions)), Set(spliceBlocks))
        XCTAssertGreaterThanOrEqual(report.overallScore, finding.score)
    }

    func testColorImagesAreAnalyzedOnLuminance() throws {
        let gray = try splicedComposite(host: 85, splice: 60, final: 85)
        let rgb = try PixelBuffer(width: size, height: size, channels: 3, pixels: gray.pixels.flatMap { [$0, $0, $0] })
        XCTAssertEqual(try ghostMap(rgb).inconsistentBlocks.map(\.region), spliceBlocks)
    }

    // MARK: - Consistent and undetectable cases

    func testUntouchedJPEGIsConsistent() throws {
        let saved = jpeg(try texture(seed: 7), quality: 85)
        let map = try ghostMap(saved)
        XCTAssertEqual(map.dominantQuality, 85)
        XCTAssertTrue(map.inconsistentBlocks.isEmpty)

        let finding = try JPEGGhostAnalyzer().analyze(Fixtures.imageData(from: saved), config: .default)
        XCTAssertEqual(finding.score, 0)
        XCTAssertTrue(finding.summary.contains("quality 85"), finding.summary)
    }

    func testSpliceResavedAtACoarserQualityIsNotDetectable() throws {
        // Documented limitation: saving the composite at 75 re-quantizes the
        // quality-90 patch onto the host's coarser grid, erasing its ghost.
        XCTAssertTrue(try ghostMap(splicedComposite(host: 75, splice: 90, final: 75)).inconsistentBlocks.isEmpty)
    }

    // MARK: - Not applicable / not assessed

    func testNeverCompressedImageIsNotApplicable() throws {
        let image = try Fixtures.imageData(from: texture(seed: 7))
        XCTAssertFalse(try ghostMap(XCTUnwrap(image.pixels)).historyPresent)
        let finding = try JPEGGhostAnalyzer().analyze(image, config: .default)
        XCTAssertEqual(finding.score, 0)
        XCTAssertTrue(finding.indicators.isEmpty)
        XCTAssertTrue(finding.summary.contains("not applicable"), finding.summary)
    }

    func testJPEGWithoutUsableGhostIsNotAssessed() throws {
        // A JPEG-tagged file whose pixels show no compression history.
        let image = ImageData(rawBytes: Fixtures.jpegBytesWithNoExif(), pixels: try texture(seed: 7), format: .jpeg)
        let finding = try JPEGGhostAnalyzer().analyze(image, config: .default)
        XCTAssertEqual(finding.score, 0)
        XCTAssertTrue(finding.summary.contains("No usable JPEG ghost"), finding.summary)
    }

    func testFlatImageIsNotAssessed() throws {
        let image = try Fixtures.imageData(from: Fixtures.uniformBuffer(width: size, height: size, channels: 1))
        let finding = try JPEGGhostAnalyzer().analyze(image, config: .default)
        XCTAssertEqual(finding.score, 0)
        XCTAssertTrue(finding.summary.contains("Only 0 of 64"), finding.summary)
    }

    func testImageTooSmallToBlockIsNotAssessed() throws {
        let image = try Fixtures.imageData(from: jpeg(Fixtures.smoothTextureBuffer(width: 40, height: 40), quality: 85))
        let finding = try JPEGGhostAnalyzer().analyze(image, config: .default)
        XCTAssertEqual(finding.score, 0)
        XCTAssertTrue(finding.summary.contains("too small"), finding.summary)
    }

    func testTooNarrowQualityRangeIsReported() throws {
        var config = ForensicLensConfig.default
        config.jpegGhost.minimumQuality = 90
        config.jpegGhost.maximumQuality = 95
        let finding = try JPEGGhostAnalyzer().analyze(Fixtures.imageData(from: splicedComposite(host: 85, splice: 60, final: 85)), config: config)
        XCTAssertEqual(finding.score, 0)
        XCTAssertTrue(finding.summary.contains("only 2 level(s)"), finding.summary)
    }

    func testImageWithoutDecodedPixelsThrowsUnsupportedInput() throws {
        let image = try ImageData.load(Fixtures.jpegBytesWithNoExif())
        XCTAssertThrowsError(try JPEGGhostAnalyzer().analyze(image, config: .default)) { error in
            guard case AnalyzerError.unsupportedInput = error else {
                return XCTFail("expected unsupportedInput, got \(error)")
            }
        }
    }

    func testBlockSizeIsRaisedAndAlignedToTheJPEGGrid() {
        XCTAssertEqual(JPEGGhostAnalyzer.effectiveBlockSize(4), 16)
        XCTAssertEqual(JPEGGhostAnalyzer.effectiveBlockSize(20), 24)
        XCTAssertEqual(JPEGGhostAnalyzer.effectiveBlockSize(32), 32)
    }

    // MARK: - Pipeline integration

    func testDisabledAnalyzerDoesNotRun() throws {
        var config = ForensicLensConfig.default
        config.jpegGhost.enabled = false
        let report = ForensicLensEngine(config: config).run(on: try Fixtures.imageData(from: texture(seed: 7)))
        XCTAssertFalse(report.findings.contains { $0.analyzerID == "jpegghost" })
        XCTAssertTrue(ForensicLensEngine(config: config).availableAnalyzerIDs.contains("jpegghost"))
    }

    func testTilingNeverSplitsGhostAnalysis() throws {
        let image = try Fixtures.imageData(from: splicedComposite(host: 85, splice: 60, final: 85))
        let engine = ForensicLensEngine(config: .default)
        let untiled = engine.run(on: image, only: ["jpegghost"], tiling: TilingOverride(disableTiling: true))
        let tiled = engine.run(on: image, only: ["jpegghost"], tiling: TilingOverride(forcedTileSize: 64))
        XCTAssertEqual(untiled.findings, tiled.findings)
        XCTAssertGreaterThan(tiled.overallScore, 0)
    }
}
