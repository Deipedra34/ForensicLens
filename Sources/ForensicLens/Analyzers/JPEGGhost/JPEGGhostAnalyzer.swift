import Foundation
import ImageDecoding

/// Finds regions that were JPEG-compressed at a different quality than the
/// rest of the image: JPEG ghost detection (Farid, 2009).
///
/// The image's luminance is re-compressed at every quality from
/// `minimumQuality` to `maximumQuality` in `qualityStep` increments, and each
/// `blockSize` block gets a curve of how much re-compression changed it at
/// each quality. Wherever a region was saved before, that curve dips, and
/// each block's lowest-quality dip is its ghost quality (see
/// `JPEGGhostMath`). The most common ghost quality is the image's own.
/// Blocks whose ghost quality is at least `disagreementThreshold` away from
/// it are flagged, typically a patch spliced in from a JPEG saved at another
/// quality. This complements ELA, which shows *that* a region's error
/// level differs, and double-compression detection, which says whether the
/// image *as a whole* was compressed twice.
///
/// **JPEG-only.** Without a compression history there are no ghosts: a
/// never-compressed image's curves just fall toward quality 100. So rather
/// than scoring such input meaninglessly, the analyzer reports it as not
/// applicable. That covers lossless originals and PNG/BMP/PPM exports that
/// never went through JPEG. A BMP or PPM *decoded from* a JPEG keeps that
/// history in its pixels and is analyzed normally. (This package can't yet
/// decode JPEG pixels itself; see `cstbi_decode_jpeg_baseline`.)
///
/// **Limitations.** A splice whose source was saved at the same quality as
/// the host leaves no disagreement to find. Re-saving the finished image at
/// a quality *lower* than the splice's original wipes that finer, earlier
/// quantization out. Uniform re-saving at low quality, resizing, or cropping
/// by an amount that isn't a multiple of 8 (which shifts the 8x8 grid this
/// analysis assumes starts at the top-left corner) weaken or erase ghosts
/// everywhere. A splice that doesn't sit on the host's 8x8 grid is only
/// partly detected.
///
/// **Cost.** One full-image luminance re-compression per swept quality (11
/// with the defaults), roughly comparable to ELA's default three-quality
/// pass over three color channels. It's linear in pixel count and runs on
/// one image-sized buffer at a time. A sparser `qualityStep` is the main
/// lever; there's no downsampling, which would destroy the 8x8 grid the
/// ghosts live on. Like PRNU and CFA, it bypasses tiling, because every
/// block is compared against one image-wide dominant quality.
public struct JPEGGhostAnalyzer: Analyzer {
    public let identifier = "jpegghost"
    public let displayName = "JPEG Ghost Detection"

    /// Smallest block size accepted; config values are raised to it and
    /// rounded up to a multiple of 8.
    static let minimumBlockSize = 16

    /// Fewest blocks for a meaningful majority.
    static let minimumBlocks = 4

    /// Fewest qualities a sweep needs to have an interior dip at all.
    static let minimumQualityCount = 3

    /// The share of judged blocks flagged at which the area part of the
    /// score saturates (as for the other block-based analyzers).
    private static let saturatingFlaggedFraction = 0.05

    public init() {}

    /// `blockSize` from config, raised to at least `minimumBlockSize` and
    /// rounded up to a multiple of 8.
    static func effectiveBlockSize(_ configured: Int) -> Int {
        let size = max(minimumBlockSize, configured)
        return (size + 7) / 8 * 8
    }

    /// The ghost map for `buffer`, or `nil` if the image holds fewer than
    /// `minimumBlocks` blocks or the quality range has fewer than
    /// `minimumQualityCount` levels. Exposed so tests and library callers
    /// can inspect the per-block heat map directly.
    static func ghostMap(for buffer: PixelBuffer, settings: ForensicLensConfig.JPEGGhostConfig) -> JPEGGhostMap? {
        let blockSize = effectiveBlockSize(settings.blockSize)
        let qualities = JPEGGhostMath.qualityLevels(minimum: settings.minimumQuality, maximum: settings.maximumQuality, step: settings.qualityStep)
        guard qualities.count >= minimumQualityCount,
              (buffer.width / blockSize) * (buffer.height / blockSize) >= minimumBlocks
        else { return nil }
        return JPEGGhostAnalysis.map(buffer, qualities: qualities, blockSize: blockSize, disagreementThreshold: max(1, settings.disagreementThreshold))
    }

    public func analyze(_ image: ImageData, config: ForensicLensConfig) throws -> AnalyzerFinding {
        guard let buffer = image.pixels else {
            throw AnalyzerError.unsupportedInput("JPEG ghost detection requires decoded pixel data, but this image has none (its format's pixel decoder is a documented stub -- see ImageDecoder).")
        }

        let settings = config.jpegGhost
        let blockSize = Self.effectiveBlockSize(settings.blockSize)
        let threshold = max(1, settings.disagreementThreshold)
        let qualities = JPEGGhostMath.qualityLevels(minimum: settings.minimumQuality, maximum: settings.maximumQuality, step: settings.qualityStep)

        guard qualities.count >= Self.minimumQualityCount else {
            return AnalyzerFinding.clean(analyzerID: identifier, summary: "The configured quality range has only \(qualities.count) level(s); JPEG ghost detection needs at least \(Self.minimumQualityCount), so it was not run.")
        }
        guard let map = Self.ghostMap(for: buffer, settings: settings) else {
            return AnalyzerFinding.clean(analyzerID: identifier, summary: "Image is too small for JPEG ghost detection: it needs at least \(Self.minimumBlocks) blocks of \(blockSize)x\(blockSize) px.")
        }
        guard map.measuredBlockCount >= Self.minimumBlocks else {
            return AnalyzerFinding.clean(analyzerID: identifier, summary: "Only \(map.measuredBlockCount) of \(map.blocks.count) block(s) have enough detail for re-compression to change them; JPEG ghost detection not assessed (low confidence).")
        }
        guard let dominant = map.dominantQuality else {
            let summary = image.format == .jpeg
                ? "No usable JPEG ghost: the file is a JPEG, but its pixels show no compression dip between quality \(qualities.first ?? 0) and \(qualities.last ?? 0) (saved at a very high quality, cropped off the 8x8 grid, or resized); not assessed (low confidence)."
                : "No JPEG compression history found: this image doesn't appear to have ever been JPEG-compressed (e.g. a lossless original or a PNG/BMP export), so JPEG ghost detection is not applicable."
            return AnalyzerFinding.clean(analyzerID: identifier, summary: summary)
        }

        let judged = map.judgedBlocks
        let flagged = map.inconsistentBlocks
        guard !flagged.isEmpty else {
            return AnalyzerFinding.clean(analyzerID: identifier, summary: "All \(judged.count) analyzed block(s) share the image's JPEG ghost at quality \(dominant); no region shows a different compression quality.")
        }

        func severity(_ block: JPEGGhostBlock) -> Double {
            guard let quality = block.ghostQuality else { return 0 }
            return min(1, Double(abs(quality - dominant)) / Double(2 * threshold))
        }
        let flaggedFraction = Double(flagged.count) / Double(max(1, judged.count))
        let areaScore = min(70, flaggedFraction / Self.saturatingFlaggedFraction * 70)
        let strengthScore = 30 * flagged.reduce(0.0) { $0 + severity($1) } / Double(flagged.count)

        let regions = flagged.map(\.region).sorted { ($0.y, $0.x) < ($1.y, $1.x) }
        let otherQualities = Set(flagged.compactMap(\.ghostQuality)).sorted().map(String.init).joined(separator: ", ")
        var indicators = [Indicator(
            message: "\(flagged.count) of \(judged.count) analyzed \(blockSize)x\(blockSize) px block(s) (\(String(format: "%.1f", flaggedFraction * 100))%) show a JPEG ghost at quality \(otherQualities), at least \(threshold) away from the image's dominant ghost at quality \(dominant).",
            weight: areaScore,
            regions: regions
        )]
        let strongest = flagged.sorted { severity($0) > severity($1) }.prefix(5)
        for block in strongest {
            indicators.append(Indicator(
                message: "Block at (\(block.region.x),\(block.region.y)) \(block.region.width)x\(block.region.height): JPEG ghost at quality \(block.ghostQuality ?? 0), versus \(dominant) for most of the image; this region was likely compressed separately, at a different quality.",
                weight: 30 * severity(block),
                regions: [block.region]
            ))
        }

        return AnalyzerFinding(
            analyzerID: identifier,
            score: areaScore + strengthScore,
            summary: "\(flagged.count) block(s) carry a JPEG ghost at a different quality (\(otherQualities)) than the rest of the image (\(dominant)), suggesting regions spliced in from a differently compressed source.",
            indicators: indicators
        )
    }
}
