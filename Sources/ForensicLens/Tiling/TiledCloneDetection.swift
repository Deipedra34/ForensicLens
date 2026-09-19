import ImageDecoding

/// Runs `CloneDetectionAnalyzer`'s copy-move search across a large image's
/// tiles, without letting tiling weaken what it can detect.
///
/// This is the one analyzer tiling can't treat like `SpatialTileMerger`
/// does. ELA and double-compression detection ask "is *this* region
/// internally consistent," a question a tile can answer entirely on its
/// own. Clone detection asks a fundamentally different question: "does
/// *this* block match *any other* block anywhere in the image" -- and nothing
/// stops a forger's source block and pasted copy from landing in two tiles
/// on opposite sides of a large photo. Comparing candidate blocks only
/// against other candidates from the *same* tile, and resetting that
/// comparison pool at every tile boundary, would silently blind clone
/// detection to exactly the cross-tile copy-moves a large image is most
/// likely to contain -- a correctness regression, not just a missed
/// optimization, which is why this exists as its own type instead of
/// going through `SpatialTileMerger`.
///
/// So instead: every tile contributes its non-flat candidate blocks (via
/// `CloneDetectionAnalyzer.candidateBlocks`, unmodified) to *one* pooled,
/// image-global candidate list, translated from each tile's local
/// coordinates into global image coordinates as they're collected. Only
/// once every tile has contributed does `CloneDetectionAnalyzer
/// .findMatches` run -- a single time, over the complete pool -- so any
/// two candidates anywhere in the image, regardless of which tile
/// extracted them, are compared against each other exactly as they would
/// be in a single, untiled pass. Tiling here only changes how the
/// candidate list is *assembled* (one tile-sized buffer at a time, instead
/// of the whole image decoded at once) -- never how it's *searched*.
///
/// One caveat worth being explicit about: `candidateBlocks` always starts
/// its scan at its buffer's own local `(0, 0)`, stepping by `blockStride`.
/// For that per-tile scan to land on the same absolute pixel positions a
/// single whole-image scan would have sampled, every tile's extraction
/// origin needs to be a multiple of `blockStride` -- which it always is
/// for `blockStride`'s default (8) and any other multiple of 8, since
/// `TilePlan` keeps every tile origin 8-aligned (see `TilePlan.alignment`
/// and `Tile`'s doc comment). A `blockStride` configured to something that
/// doesn't divide evenly into 8 can shift each tile's sampled grid out of
/// phase with its neighbors', the same way an untuned `tileOverlap` would
/// for ELA -- worth knowing if `blockStride` is ever hand-tuned away from
/// an 8-multiple on a large, tiled image.
enum TiledCloneDetection {
    static func run(image: ImageData, config: ForensicLensConfig) throws -> AnalyzerFinding {
        guard let fullBuffer = image.pixels else {
            throw AnalyzerError.unsupportedInput("Clone detection requires decoded pixel data, but this image has none.")
        }

        let settings = config.cloneDetection
        let blockSize = max(4, settings.blockSize)
        let stride = max(1, settings.blockStride)

        guard fullBuffer.width >= blockSize, fullBuffer.height >= blockSize else {
            return AnalyzerFinding.clean(analyzerID: "clone", summary: "Image is smaller than one comparison block; nothing to compare.")
        }

        // A block that starts anywhere inside a tile's core can extend up
        // to `blockSize - 1` pixels past the core's edge, so the halo used
        // to extract each tile must reach at least that far -- independent
        // of `config.tiling.tileOverlap`, which is sized for ELA/double-
        // compression's 8x8 grid, not for whatever `blockSize` clone
        // detection happens to be configured with. Using the larger of the
        // two here means correctness never depends on the user having
        // picked a big enough `tileOverlap` for clone detection
        // specifically.
        //
        // `blockSize` is rounded *up* to a multiple of 8 before that
        // comparison, not just passed through: `TilePlan.build` rounds its
        // own `halo` argument to the *nearest* multiple of 8 (see
        // `TilePlan.sanitizedHalo`), which for a `blockSize` that isn't
        // itself already a multiple of 8 (e.g. 20, 25 -- an unusual but
        // legal `cloneDetection.blockSize` in `forensiclens.yaml`) could
        // otherwise round back down below `blockSize` and reopen exactly
        // the missed-block gap this halo exists to close.
        let blockSizeCeiledTo8 = ((blockSize + 7) / 8) * 8
        let halo = max(config.tiling.tileOverlap, blockSizeCeiledTo8)
        let tiles = TilePlan.build(imageWidth: fullBuffer.width, imageHeight: fullBuffer.height, tileSize: config.tiling.tileSize, halo: halo)

        guard !tiles.isEmpty else {
            let candidates = CloneDetectionAnalyzer.candidateBlocks(fullBuffer, blockSize: blockSize, stride: stride, minimumVariance: settings.minimumBlockVariance)
            let matches = CloneDetectionAnalyzer.findMatches(candidates, similarityThreshold: settings.similarityThreshold, minimumDistance: settings.minimumBlockDistance)
            return CloneDetectionAnalyzer.makeFinding(analyzerID: "clone", matches: matches, imageWidth: fullBuffer.width, imageHeight: fullBuffer.height, settings: settings)
        }

        // Small (position + a 16-`Double` feature vector each), so pooling
        // every tile's candidates for the whole image costs a tiny
        // fraction of what holding the pixels themselves would -- this is
        // what's actually deferred until every tile has contributed, not
        // any pixel data.
        var globalCandidates: [CloneDetectionAnalyzer.Candidate] = []

        for tile in tiles {
            // Only one tile's pixels are ever resident here; it's dropped
            // at the end of this iteration once its candidates (tiny,
            // pixel-free descriptors) have been pooled.
            let tileBuffer = try fullBuffer.extracting(tile.extract)
            let localCandidates = CloneDetectionAnalyzer.candidateBlocks(tileBuffer, blockSize: blockSize, stride: stride, minimumVariance: settings.minimumBlockVariance)

            for candidate in localCandidates {
                let globalX = candidate.position.x + tile.extract.x
                let globalY = candidate.position.y + tile.extract.y

                // Keep a global block position only if it falls inside
                // *this* tile's exclusive core -- every other tile whose
                // extraction halo also happened to cover this position
                // skips it, since core rects exactly partition the image.
                // Without this filter, a block near a tile boundary would
                // be pooled once per tile that overlaps it, inflating the
                // match count with duplicate candidates for the same
                // physical block.
                guard globalX >= tile.core.x, globalX < tile.core.x + tile.core.width,
                      globalY >= tile.core.y, globalY < tile.core.y + tile.core.height
                else { continue }

                globalCandidates.append(CloneDetectionAnalyzer.Candidate(
                    position: CloneDetectionAnalyzer.BlockPosition(x: globalX, y: globalY),
                    feature: candidate.feature
                ))
            }
        }

        guard globalCandidates.count >= 2 else {
            return AnalyzerFinding.clean(analyzerID: "clone", summary: "No non-uniform regions found to compare; image may be flat or too small.")
        }

        let matches = CloneDetectionAnalyzer.findMatches(globalCandidates, similarityThreshold: settings.similarityThreshold, minimumDistance: settings.minimumBlockDistance)
        return CloneDetectionAnalyzer.makeFinding(analyzerID: "clone", matches: matches, imageWidth: fullBuffer.width, imageHeight: fullBuffer.height, settings: settings)
    }
}
