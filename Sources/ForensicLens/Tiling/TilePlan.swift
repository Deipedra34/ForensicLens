/// A rectangular region of a larger image, in pixel coordinates.
struct PixelRect: Equatable, Sendable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int
}

/// One tile in a `TilePlan`.
///
/// A tile has two rectangles, not one, because a per-tile analysis pass
/// needs two different notions of "this tile's region":
///
/// - `core` is the slice of the image this tile *owns*. The set of `core`
///   rects across a whole `TilePlan` exactly partitions the source image --
///   no gaps, no overlap -- which is what makes combining per-tile results
///   safe: crediting a finding to "the tile whose core contains it" can
///   never double-count a pixel, because every pixel belongs to exactly one
///   tile's core.
/// - `extract` is `core` expanded by a halo on every side (clamped to the
///   image bounds), and is the region an analyzer actually reads pixels
///   from. The halo exists so a windowed computation near `core`'s edge --
///   an 8x8 DCT block, a clone-detection comparison block -- sees real
///   neighboring image content instead of a synthetic replicated edge, the
///   way `JPEGRecompressionSimulator` pads a block that runs off the true
///   image edge. Without it, every tile boundary would look like a fake
///   image edge to the analyzer running on it, and that fake-edge artifact
///   would show up as a seam in the merged result.
struct Tile: Equatable, Sendable {
    let core: PixelRect
    let extract: PixelRect

    /// `core`'s origin, expressed in `extract`-local coordinates. Useful
    /// for translating a position found while scanning `extract`'s pixels
    /// back into global image coordinates and testing whether it falls
    /// inside this tile's exclusive core ownership area.
    var coreOriginInExtract: (x: Int, y: Int) {
        (core.x - extract.x, core.y - extract.y)
    }
}

/// Builds the grid of overlapping `Tile`s a large `PixelBuffer` is split
/// into for tiled analysis. See `ForensicLensConfig.TilingConfig` for the
/// user-facing configuration this reads its `tileSize`/`halo` inputs from.
enum TilePlan {
    /// The JPEG DCT block size ELA and double-compression detection are
    /// both anchored to. `tileSize` and `halo` are each rounded to a
    /// multiple of this so every tile's core origin (`tileSize`-aligned)
    /// and extraction origin (`core origin - halo`) stay on the same 8x8
    /// grid phase a single-block pass over the whole image would use --
    /// see `Tile`'s doc comment and `ForensicLensConfig.TilingConfig
    /// .tileOverlap`'s doc comment for why that phase-alignment matters.
    private static let alignment = 8

    /// Builds the tile grid for an `imageWidth` x `imageHeight` image.
    ///
    /// Tiling always starts at `(0, 0)` and steps by the sanitized tile
    /// size, so every row and column of tiles fully covers the image; the
    /// last tile in each row/column is simply smaller than `tileSize` when
    /// the image doesn't divide evenly (a "partial edge tile"), rather than
    /// being dropped or padded.
    ///
    /// Returns an empty array for a non-positive `imageWidth`/`imageHeight`
    /// (should not happen for a valid `PixelBuffer`, but handled rather
    /// than assumed).
    static func build(imageWidth: Int, imageHeight: Int, tileSize rawTileSize: Int, halo rawHalo: Int) -> [Tile] {
        guard imageWidth > 0, imageHeight > 0 else { return [] }

        let tileSize = sanitizedTileSize(rawTileSize)
        let halo = sanitizedHalo(rawHalo, tileSize: tileSize)

        var tiles: [Tile] = []
        var y = 0
        while y < imageHeight {
            let coreHeight = min(tileSize, imageHeight - y)
            var x = 0
            while x < imageWidth {
                let coreWidth = min(tileSize, imageWidth - x)
                let core = PixelRect(x: x, y: y, width: coreWidth, height: coreHeight)

                let extractX0 = max(0, x - halo)
                let extractY0 = max(0, y - halo)
                let extractX1 = min(imageWidth, x + coreWidth + halo)
                let extractY1 = min(imageHeight, y + coreHeight + halo)
                let extract = PixelRect(x: extractX0, y: extractY0, width: extractX1 - extractX0, height: extractY1 - extractY0)

                tiles.append(Tile(core: core, extract: extract))
                x += tileSize
            }
            y += tileSize
        }
        return tiles
    }

    /// Rounds `tileSize` to the nearest multiple of `alignment`, with a
    /// floor of `alignment` itself so a tiny or zero/negative configured
    /// value (e.g. a hand-edited `forensiclens.yaml`, or a careless
    /// `--tile-size`) still produces usable tiles instead of an infinite
    /// or zero-progress loop in `build`.
    static func sanitizedTileSize(_ tileSize: Int) -> Int {
        let clamped = max(alignment, tileSize)
        let rounded = Int((Double(clamped) / Double(alignment)).rounded()) * alignment
        return max(alignment, rounded)
    }

    /// Rounds `halo` to the nearest multiple of `alignment` (see
    /// `TilePlan.alignment`'s doc comment for why), clamping it to
    /// `[0, tileSize]`: a halo doesn't need to reach further than one whole
    /// tile's width to supply full context, and an unbounded halo would
    /// undermine tiling's whole memory-bounding purpose by pulling in
    /// arbitrarily large amounts of neighboring image data.
    static func sanitizedHalo(_ halo: Int, tileSize: Int) -> Int {
        let clamped = max(0, halo)
        let rounded = Int((Double(clamped) / Double(alignment)).rounded()) * alignment
        return min(max(0, rounded), tileSize)
    }
}
