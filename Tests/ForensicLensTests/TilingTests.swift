import XCTest
@testable import ForensicLens
import ImageDecoding

final class TilingTests: XCTestCase {
    // MARK: - Tile geometry

    /// The set of `core` rects across a `TilePlan` must partition the
    /// image exactly: every pixel covered by exactly one tile's core, no
    /// gaps, no overlap. This is what makes per-tile results safe to
    /// combine without double-counting -- see `Tile`'s doc comment.
    ///
    /// `imageWidth`/`imageHeight` (100x100) and `tileSize` (48) are chosen
    /// so the image does *not* divide evenly into tiles, exercising
    /// partial edge tiles specifically -- 100 = 48 + 48 + 4, so the last
    /// tile in each row/column is only 4px wide/tall.
    func testCoreTilesPartitionTheImageExactlyIncludingPartialEdgeTiles() {
        let imageWidth = 100
        let imageHeight = 100
        let tiles = TilePlan.build(imageWidth: imageWidth, imageHeight: imageHeight, tileSize: 48, halo: 8)

        XCTAssertGreaterThan(tiles.count, 1, "a 100x100 image with a 48px tile size should actually produce multiple tiles")

        var coverage = [Bool](repeating: false, count: imageWidth * imageHeight)
        var totalCoreArea = 0
        for tile in tiles {
            XCTAssertGreaterThan(tile.core.width, 0)
            XCTAssertGreaterThan(tile.core.height, 0)
            totalCoreArea += tile.core.width * tile.core.height

            for y in tile.core.y..<(tile.core.y + tile.core.height) {
                for x in tile.core.x..<(tile.core.x + tile.core.width) {
                    let index = y * imageWidth + x
                    XCTAssertFalse(coverage[index], "pixel (\(x),\(y)) covered by more than one tile's core")
                    coverage[index] = true
                }
            }
        }

        XCTAssertEqual(totalCoreArea, imageWidth * imageHeight)
        XCTAssertTrue(coverage.allSatisfy { $0 }, "every pixel should be covered by exactly one tile's core")
    }

    /// Extracting every tile's (core-plus-halo) `extract` rect from a real
    /// buffer must never throw or crash, even for the partial edge tiles
    /// at the image's right/bottom boundary.
    func testExtractingEveryTileRectSucceedsWithoutCrashingOnPartialEdgeTiles() throws {
        let buffer = try Fixtures.noiseBuffer(width: 100, height: 100, seed: 7)
        let tiles = TilePlan.build(imageWidth: buffer.width, imageHeight: buffer.height, tileSize: 48, halo: 8)

        for tile in tiles {
            let extracted = try buffer.extracting(tile.extract)
            XCTAssertEqual(extracted.width, tile.extract.width)
            XCTAssertEqual(extracted.height, tile.extract.height)
        }
    }

    func testSanitizedTileSizeRoundsToNearestMultipleOfEightWithAFloor() {
        XCTAssertEqual(TilePlan.sanitizedTileSize(1024), 1024)
        XCTAssertEqual(TilePlan.sanitizedTileSize(17), 16)
        XCTAssertEqual(TilePlan.sanitizedTileSize(0), 8)
        XCTAssertEqual(TilePlan.sanitizedTileSize(-5), 8)
    }

    func testSanitizedHaloRoundsToMultipleOfEightAndClampsToTileSize() {
        XCTAssertEqual(TilePlan.sanitizedHalo(64, tileSize: 1024), 64)
        XCTAssertEqual(TilePlan.sanitizedHalo(1000, tileSize: 64), 64, "halo should never exceed one tile's own size")
        XCTAssertEqual(TilePlan.sanitizedHalo(-10, tileSize: 64), 0)
    }

    func testEmptyImageDimensionsProduceNoTiles() {
        XCTAssertTrue(TilePlan.build(imageWidth: 0, imageHeight: 100, tileSize: 64, halo: 8).isEmpty)
        XCTAssertTrue(TilePlan.build(imageWidth: 100, imageHeight: 0, tileSize: 64, halo: 8).isEmpty)
    }

    // MARK: - Automatic activation

    func testTilingActivatesAutomaticallyOnlyAboveTheConfiguredThreshold() throws {
        var config = ForensicLensConfig.default
        config.tiling.tilingThreshold = 100
        config.tiling.tileSize = 48
        config.tiling.tileOverlap = 16

        let smallImage = try Fixtures.imageData(from: try Fixtures.uniformBuffer(width: 64, height: 64))
        XCTAssertNil(TilingCoordinator.plan(for: smallImage, config: config, override: .none), "images at or below tilingThreshold must stay untiled")

        let largeImage = try Fixtures.imageData(from: try Fixtures.uniformBuffer(width: 200, height: 200))
        let plan = TilingCoordinator.plan(for: largeImage, config: config, override: .none)
        XCTAssertNotNil(plan)
        XCTAssertGreaterThan(plan?.count ?? 0, 1)
    }

    func testTilingDisabledInConfigNeverActivatesRegardlessOfSize() throws {
        var config = ForensicLensConfig.default
        config.tiling.enabled = false
        config.tiling.tilingThreshold = 50

        let largeImage = try Fixtures.imageData(from: try Fixtures.uniformBuffer(width: 200, height: 200))
        XCTAssertNil(TilingCoordinator.plan(for: largeImage, config: config, override: .none))
    }

    // MARK: - CLI-style overrides

    func testNoTilingOverrideForcesSingleBlockEvenAboveThreshold() throws {
        var config = ForensicLensConfig.default
        config.tiling.tilingThreshold = 50

        let largeImage = try Fixtures.imageData(from: try Fixtures.uniformBuffer(width: 200, height: 200))
        XCTAssertNil(TilingCoordinator.plan(for: largeImage, config: config, override: TilingOverride(disableTiling: true)))
    }

    func testForcedTileSizeOverrideActivatesTilingBelowThreshold() throws {
        // Default config: a 128x128 image sits well under the default
        // tilingThreshold (4096), so it would never tile on its own.
        let config = ForensicLensConfig.default
        let image = try Fixtures.imageData(from: try Fixtures.uniformBuffer(width: 128, height: 128))

        XCTAssertNil(TilingCoordinator.plan(for: image, config: config, override: .none))

        let forced = TilingCoordinator.plan(for: image, config: config, override: TilingOverride(forcedTileSize: 32))
        XCTAssertNotNil(forced)
        XCTAssertGreaterThan(forced?.count ?? 0, 1)
        XCTAssertTrue(forced?.allSatisfy { $0.core.width <= 32 && $0.core.height <= 32 } ?? false)
    }

    // MARK: - Tiled vs. untiled score equivalence

    /// A noise patch big enough, relative to both the whole image and to
    /// one tile, that ELA's coverage score saturates its own 60-point cap
    /// in *both* modes regardless of which area the "hot fraction" is
    /// computed against. Once both modes hit that cap, and the patch's 8x8
    /// blocks land on the same global grid phase in both (tile origins are
    /// kept 8-aligned -- see `TilePlan`), the merged tiled score and the
    /// single-block score should come out very close to each other, which
    /// is what this test checks.
    func testNoTilingOverrideProducesMateriallyEquivalentELAScoreToForcedTiling() throws {
        let base = try Fixtures.uniformBuffer(width: 256, height: 256, value: 100)
        // Aligned to an 8x8 DCT block boundary and to the 16x16 ELA
        // reporting-cell grid, and fully contained within one 64px tile
        // core (the core spanning x/y 64..<128) so exactly one tile is hot.
        let withPatch = try Fixtures.stampingNoisePatch(of: 48, at: (x: 72, y: 72), into: base)
        let image = try Fixtures.imageData(from: withPatch)

        var config = ForensicLensConfig.default
        config.ela.errorThreshold = 10
        config.ela.flaggedRegionFraction = 0.015

        let engine = ForensicLensEngine(config: config)
        let untiled = engine.run(on: image, only: ["ela"], tiling: TilingOverride(disableTiling: true))
        let tiled = engine.run(on: image, only: ["ela"], tiling: TilingOverride(forcedTileSize: 64))

        XCTAssertGreaterThan(untiled.overallScore, 0)
        XCTAssertGreaterThan(tiled.overallScore, 0)
        XCTAssertLessThanOrEqual(
            abs(untiled.overallScore - tiled.overallScore), 10,
            "tiled (\(tiled.overallScore)) and untiled (\(untiled.overallScore)) ELA scores should be materially equivalent on the same image"
        )
    }

    // MARK: - Cross-tile clone detection (correctness requirement)

    /// The core correctness guarantee of tiled clone detection: a
    /// copy-move whose source and pasted copy land in two distant tiles
    /// must still be found, because the candidate index is pooled globally
    /// across every tile before matching runs -- see `TiledCloneDetection`'s
    /// doc comment. This also demonstrates *why* that global pooling
    /// matters: analyzing either tile alone finds nothing.
    func testCloneSpanningTwoDistantTilesIsStillDetected() throws {
        let base = try Fixtures.noiseBuffer(width: 256, height: 256, seed: 42)
        // Source block in the top-left tile, pasted copy in the
        // bottom-right tile -- opposite corners of a 4x4 grid of 64px
        // tiles. Both corners are multiples of the default blockStride
        // (8), matching the alignment `CloneDetectionAnalyzerTests`
        // already relies on for an exact block match.
        let withClone = try Fixtures.pastingPatch(of: 24, from: (x: 8, y: 8), to: (x: 200, y: 200), into: base)
        let image = try Fixtures.imageData(from: withClone)

        let config = ForensicLensConfig.default
        let engine = ForensicLensEngine(config: config)

        let tiledFinding = engine.run(on: image, only: ["clone"], tiling: TilingOverride(forcedTileSize: 64))
        XCTAssertGreaterThan(tiledFinding.overallScore, 0, "a clone spanning two distant tiles must still be detected once candidates are pooled globally")

        // Demonstrate the failure mode a naive per-tile-only search would
        // have: neither tile, analyzed in isolation, contains both the
        // source and the copy, so a plain (untiled) analysis of just one
        // tile's extracted pixels finds nothing.
        guard let fullBuffer = image.pixels else { return XCTFail("expected decoded pixels") }
        let tiles = TilePlan.build(imageWidth: fullBuffer.width, imageHeight: fullBuffer.height, tileSize: 64, halo: config.tiling.tileOverlap)
        guard let sourceTile = tiles.first(where: { $0.core.x == 0 && $0.core.y == 0 }) else {
            return XCTFail("expected a tile covering the source patch's origin")
        }
        let sourceTileBuffer = try fullBuffer.extracting(sourceTile.extract)
        let sourceTileImage = ImageData(rawBytes: image.rawBytes, pixels: sourceTileBuffer, format: image.format)
        let isolatedFinding = try CloneDetectionAnalyzer().analyze(sourceTileImage, config: config)
        XCTAssertEqual(isolatedFinding.score, 0, "the source tile alone shouldn't contain its own pasted copy")
    }

    func testCloneWithinASingleTileIsStillDetected() throws {
        let base = try Fixtures.noiseBuffer(width: 256, height: 256, seed: 42)
        // Both corners inside the same top-left 64px tile core.
        let withClone = try Fixtures.pastingPatch(of: 16, from: (x: 8, y: 8), to: (x: 40, y: 40), into: base)
        let image = try Fixtures.imageData(from: withClone)

        let engine = ForensicLensEngine(config: .default)
        let finding = engine.run(on: image, only: ["clone"], tiling: TilingOverride(forcedTileSize: 64))
        XCTAssertGreaterThan(finding.overallScore, 0)
    }

    // MARK: - Metadata stays untiled

    /// Metadata analysis has no spatial component -- it reads EXIF once
    /// from the raw file bytes -- so it must produce the identical finding
    /// whether or not tiling is active for the rest of the report.
    func testMetadataFindingIsIdenticalWhetherOrNotTilingIsForced() throws {
        // Tag the bytes as JPEG (metadata only runs on JPEG) without a real
        // EXIF segment; MetadataAnalyzer only needs `image.format` and
        // `image.rawBytes` here, not decodable JPEG pixels.
        let buffer = try Fixtures.noiseBuffer(width: 128, height: 128, seed: 3)
        let image = ImageData(rawBytes: Fixtures.jpegBytesWithNoExif(), pixels: buffer, format: .jpeg)

        let engine = ForensicLensEngine(config: .default)
        let untiled = engine.run(on: image, only: ["metadata"], tiling: TilingOverride(disableTiling: true))
        let tiled = engine.run(on: image, only: ["metadata"], tiling: TilingOverride(forcedTileSize: 32))

        XCTAssertEqual(untiled.overallScore, tiled.overallScore)
        XCTAssertEqual(untiled.findings.first?.summary, tiled.findings.first?.summary)
    }
}
