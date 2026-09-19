import ImageDecoding

/// A CLI-level override of `ForensicLensEngine`'s ordinary, threshold-driven
/// tiling decision -- for comparing tiled and untiled output on the same
/// image, per this feature's `--tile-size` / `--no-tiling` CLI flags.
/// Library callers that don't need this can just use `.none`, which leaves
/// `ForensicLensConfig.TilingConfig` in full control, exactly as if this
/// override didn't exist.
public struct TilingOverride: Sendable {
    /// Forces tiling on at this tile size, bypassing `tilingThreshold` --
    /// so tiling can be exercised and compared even on an image that
    /// wouldn't normally be large enough to trigger it. Ignored if
    /// `disableTiling` is also set.
    public var forcedTileSize: Int?

    /// Forces every image to be processed as a single block, regardless of
    /// its size or `ForensicLensConfig.TilingConfig.enabled`.
    public var disableTiling: Bool

    public init(forcedTileSize: Int? = nil, disableTiling: Bool = false) {
        self.forcedTileSize = forcedTileSize
        self.disableTiling = disableTiling
    }

    /// No override: follow `config.tiling` exactly as configured.
    public static let none = TilingOverride()
}

/// Decides whether a given image should be processed as a single block
/// (today's behavior, unchanged) or split into tiles, and if tiled,
/// dispatches each analyzer to the tiling strategy appropriate for it.
///
/// This is the only place `ForensicLensEngine` reaches for tiling logic,
/// and it's the seam that keeps requirement 1 ("images at or below the
/// threshold are processed exactly as before") literally true: when
/// `plan(for:config:override:)` returns `nil`, `run` below calls
/// `analyzer.analyze(image, config: config)` directly -- the exact same
/// call `ForensicLensEngine.run` made before tiling existed, with nothing
/// in between.
enum TilingCoordinator {
    /// Returns the tile grid to use for `image`, or `nil` if it should be
    /// processed as a single block.
    static func plan(for image: ImageData, config: ForensicLensConfig, override: TilingOverride) -> [Tile]? {
        guard let buffer = image.pixels else { return nil }
        guard !override.disableTiling else { return nil }

        let tileSize: Int
        if let forced = override.forcedTileSize {
            tileSize = forced
        } else {
            guard config.tiling.enabled else { return nil }
            let largerDimension = max(buffer.width, buffer.height)
            guard largerDimension > config.tiling.tilingThreshold else { return nil }
            tileSize = config.tiling.tileSize
        }

        let tiles = TilePlan.build(imageWidth: buffer.width, imageHeight: buffer.height, tileSize: tileSize, halo: config.tiling.tileOverlap)

        // A "grid" of exactly one tile covers the whole image anyway, so
        // treat it as "don't tile" rather than pay tiling's bookkeeping
        // (and, for clone detection, the extra core/halo filtering pass)
        // for no bound-memory benefit.
        guard tiles.count > 1 else { return nil }
        return tiles
    }

    /// Runs `analyzer` against `image`, using `tiles` if non-nil or as a
    /// single block otherwise.
    ///
    /// Metadata always runs as a single block even when `tiles` is
    /// non-nil: it reads EXIF once from `image.rawBytes`, has no spatial
    /// component, and gains nothing from tiling -- see `MetadataAnalyzer`'s
    /// doc comment. Clone detection is dispatched to `TiledCloneDetection`
    /// instead of `SpatialTileMerger`, since its cross-tile correctness
    /// requirement (a source/copy pair split across two tiles must still
    /// be found) needs a global candidate index rather than independently
    /// merged per-tile findings -- see that type's doc comment. Every other
    /// analyzer goes through `SpatialTileMerger`.
    static func run(_ analyzer: any Analyzer, image: ImageData, tiles: [Tile]?, config: ForensicLensConfig) throws -> AnalyzerFinding {
        guard let tiles else {
            return try analyzer.analyze(image, config: config)
        }

        switch analyzer.identifier {
        case "metadata":
            return try analyzer.analyze(image, config: config)
        case "clone":
            return try TiledCloneDetection.run(image: image, config: config)
        default:
            return try SpatialTileMerger.run(analyzer, image: image, tiles: tiles, config: config)
        }
    }
}
