import ImageDecoding

/// Runs a spatial `Analyzer` (ELA, double-compression detection) across a
/// large image's tiles and merges the per-tile results into one
/// image-wide `AnalyzerFinding`.
///
/// This is deliberately the *only* place tiling touches these analyzers.
/// `analyzer.analyze(_:config:)` is called once per tile, completely
/// unchanged -- the same method, the same code path, the same scoring
/// math a small, untiled image goes through -- against a tile-sized
/// `PixelBuffer`. ELA and double-compression detection stay entirely
/// tile-unaware: from inside `analyze`, a tile just looks like a small
/// image.
enum SpatialTileMerger {
    /// Runs `analyzer` once per tile and combines the results.
    ///
    /// - Parameters:
    ///   - image: The full source image. Only `image.pixels` is sliced per
    ///     tile; `rawBytes` and `format` are passed through unchanged to
    ///     each tile's `ImageData` so format-gated analyzers (e.g.
    ///     `DoubleCompressionAnalyzer`'s JPEG-only check) behave the same
    ///     way per tile as they would on the whole file.
    ///   - tiles: The tile grid to run over, from `TilePlan.build`.
    static func run(_ analyzer: any Analyzer, image: ImageData, tiles: [Tile], config: ForensicLensConfig) throws -> AnalyzerFinding {
        guard let fullBuffer = image.pixels else {
            throw AnalyzerError.unsupportedInput("\(analyzer.displayName) requires decoded pixel data, but this image has none.")
        }
        guard !tiles.isEmpty else {
            return try analyzer.analyze(image, config: config)
        }

        // Tiles are processed one at a time, and only each tile's small
        // `AnalyzerFinding` (a score, a summary string, a handful of
        // indicators) is retained afterward -- not the tile's pixel
        // buffer, which is dropped at the end of each loop iteration. Peak
        // extra memory here is one tile's worth of pixels, not
        // `tiles.count` tiles' worth.
        var tileFindings: [(tile: Tile, finding: AnalyzerFinding)] = []
        tileFindings.reserveCapacity(tiles.count)

        for tile in tiles {
            let tileBuffer = try fullBuffer.extracting(tile.extract)
            let tileImage = ImageData(rawBytes: image.rawBytes, pixels: tileBuffer, format: image.format)
            let finding = try analyzer.analyze(tileImage, config: config)
            tileFindings.append((tile, finding))
        }

        return merge(tileFindings, analyzerID: analyzer.identifier)
    }

    /// Combines this analyzer's independent per-tile findings into one
    /// image-wide finding.
    ///
    /// The obvious-looking approach -- sum or average every tile's score --
    /// is exactly wrong here. Tiles overlap on purpose (see `Tile`'s doc
    /// comment): a genuine anomaly sitting in the halo shared by two
    /// neighboring tiles gets picked up independently by both of them, so
    /// summing their scores would double-count the exact same evidence and
    /// inflate the merged score past what a single-block pass over the
    /// same image would ever report. Averaging has the opposite problem:
    /// it dilutes one strongly tampered tile by every quiet, untampered
    /// tile around it, which is precisely the failure mode
    /// `SuspicionScorer`'s own doc comment already rejects for combining
    /// different analyzers, and applies just as much to combining the same
    /// analyzer across tiles.
    ///
    /// So this takes the strongest single tile's score as the dominant
    /// signal -- taking a max, rather than a sum, means a duplicate
    /// detection in a shared overlap region never counts twice, since
    /// `max(x, x) == x` regardless of how many tiles independently found
    /// it -- and lets other hot tiles nudge the score up only slightly, the
    /// same dominant-plus-corroboration shape `SuspicionScorer` uses to
    /// combine different analyzers' findings.
    private static func merge(_ tileFindings: [(tile: Tile, finding: AnalyzerFinding)], analyzerID: String) -> AnalyzerFinding {
        let hot = tileFindings.filter { $0.finding.score > 0 }.sorted { $0.finding.score > $1.finding.score }

        guard let dominant = hot.first else {
            // A format-gated analyzer (double-compression detection on a
            // non-JPEG image) reports the same specific "not applicable"
            // summary from every tile, since `image.format` is passed
            // through unchanged to each one -- reuse that shared summary
            // rather than replacing it with a generic message that would
            // throw away the actual reason. Falls back to a generic
            // message only when the tiles' clean summaries actually
            // differ.
            let summaries = Set(tileFindings.map(\.finding.summary))
            let sharedSummary: String? = summaries.count == 1 ? summaries.first : nil
            let summary = sharedSummary ?? "No anomalies detected across \(tileFindings.count) tile(s)."
            return AnalyzerFinding.clean(analyzerID: analyzerID, summary: summary)
        }

        // Kept small and capped so a large number of mildly-hot tiles (or
        // the same real anomaly re-detected in a couple of overlapping
        // tiles) can't stack up into a falsely confident score -- mirrors
        // `SuspicionScorer.corroborationWeight`'s own reasoning.
        let corroborationWeight = 0.05
        let corroboration = min(20, hot.dropFirst().reduce(0.0) { $0 + $1.finding.score * corroborationWeight })
        let score = min(100, dominant.finding.score + corroboration)

        var indicators: [Indicator] = []
        for (tile, finding) in hot.prefix(5) {
            for indicator in finding.indicators.prefix(3) {
                indicators.append(Indicator(
                    message: "[tile at (\(tile.core.x),\(tile.core.y))] \(indicator.message)",
                    weight: indicator.weight
                ))
            }
        }

        let summary = "\(hot.count) of \(tileFindings.count) tile(s) flagged; strongest at tile (\(dominant.tile.core.x),\(dominant.tile.core.y)): \(dominant.finding.summary)"

        return AnalyzerFinding(analyzerID: analyzerID, score: score, summary: summary, indicators: indicators)
    }
}
