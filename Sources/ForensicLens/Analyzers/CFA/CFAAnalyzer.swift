import Foundation
import ImageDecoding

/// Detects regions whose color-filter-array (CFA) demosaicing trace is
/// missing or disagrees with the rest of the image.
///
/// A camera with a Bayer sensor records one color per pixel and
/// interpolates the other two, which leaves a period-2 pattern of
/// predictable and unpredictable samples in every color channel (see
/// `CFAPeriodicity`). A region spliced in from another source, rendered or
/// generated, resized, or retouched with a brush that resamples pixels
/// usually lacks that pattern, or carries it on a differently aligned grid.
/// The image is split into `blockSize` blocks, each block's trace strength
/// is compared against the image's own median (`CFALocalConsistency`), and
/// blocks below `consistencyThreshold` are flagged.
///
/// **A supporting signal, not a verdict.** The trace is fragile and
/// depends on how the image was produced:
///
/// - **Recompression and resizing** weaken or erase it. JPEG quantization
///   smooths the interpolation contrast away, and any resampling replaces
///   the sensor lattice with a new one. An image with no trace left at all
///   is reported as "not assessed" with score 0, since that describes most
///   images that have been shared online, not just forged ones.
/// - **Computational-photography pipelines** (modern phones merging several
///   exposures, multi-frame denoising, super-resolution, AI upscaling)
///   often produce output with no CFA trace, or a different one, because
///   the final pixels were never demosaiced from a single raw frame.
/// - **Heavy denoising and sharpening** alter neighboring-pixel
///   correlations and can mask or mimic the pattern.
/// - **Flat, clipped, or noiseless areas** carry no detail to reveal it,
///   so such blocks are skipped.
///
/// Grayscale images have no color channels to analyze and are reported as
/// not applicable. Cost is a single pass over each channel with a 4-pixel
/// predictor, plus a median per lattice phase per block. That's linear in
/// pixel count, and memory stays at a few block-sized planes. Unlike PRNU
/// analysis it never downsamples, because resampling would destroy the very
/// lattice it measures. Like PRNU it bypasses the tiling layer: every block
/// is compared against an image-wide baseline and lattice phase.
public struct CFAAnalyzer: Analyzer {
    public let identifier = "cfa"
    public let displayName = "CFA Demosaicing Consistency"

    /// Smallest block size accepted; smaller (or odd) config values are
    /// raised to the next even size at least this large. Below it a block
    /// has too few samples per lattice phase for a stable median.
    static let minimumBlockSize = 16

    /// Fewest reliable blocks for a meaningful comparison.
    static let minimumReliableBlocks = 4

    /// The share of reliable blocks flagged at which the area part of the
    /// score saturates (as for PRNU).
    private static let saturatingFlaggedFraction = 0.05

    public init() {}

    /// `blockSize` from config, raised to at least `minimumBlockSize` and
    /// rounded up to an even number so every block starts on the same
    /// lattice phase.
    static func effectiveBlockSize(_ configured: Int) -> Int {
        let size = max(minimumBlockSize, configured)
        return size % 2 == 0 ? size : size + 1
    }

    /// The consistency map for `buffer`, or `nil` if the image is
    /// grayscale or too small to hold `minimumReliableBlocks` blocks.
    /// Exposed so tests and library callers can inspect the per-block heat
    /// map directly.
    static func consistencyMap(for buffer: PixelBuffer, settings: ForensicLensConfig.CFAConfig) -> CFAConsistencyMap? {
        let blockSize = effectiveBlockSize(settings.blockSize)
        guard buffer.channels >= 3,
              (buffer.width / blockSize) * (buffer.height / blockSize) >= minimumReliableBlocks
        else { return nil }
        return CFALocalConsistency.map(buffer, blockSize: blockSize, threshold: settings.consistencyThreshold)
    }

    public func analyze(_ image: ImageData, config: ForensicLensConfig) throws -> AnalyzerFinding {
        guard let buffer = image.pixels else {
            throw AnalyzerError.unsupportedInput("CFA analysis requires decoded pixel data, but this image has none.")
        }

        let settings = config.cfa
        let blockSize = Self.effectiveBlockSize(settings.blockSize)
        let threshold = settings.consistencyThreshold

        guard buffer.channels >= 3 else {
            return AnalyzerFinding.clean(analyzerID: identifier, summary: "Grayscale image: there are no color channels to carry a demosaicing pattern, so CFA analysis is not applicable.")
        }
        guard let map = Self.consistencyMap(for: buffer, settings: settings) else {
            return AnalyzerFinding.clean(analyzerID: identifier, summary: "Image is too small for a CFA consistency check: it needs at least \(Self.minimumReliableBlocks) blocks of \(blockSize)x\(blockSize) px.")
        }

        guard map.measuredBlockCount >= Self.minimumReliableBlocks else {
            return AnalyzerFinding.clean(
                analyzerID: identifier,
                summary: "Only \(map.measuredBlockCount) of \(map.blocks.count) block(s) have enough unclipped detail to look for a CFA demosaicing pattern; CFA consistency not assessed (low confidence)."
            )
        }

        let strength = String(format: "%.2f", map.imageStrength)
        guard map.tracePresent else {
            return AnalyzerFinding.clean(
                analyzerID: identifier,
                summary: "No consistent CFA demosaicing pattern across the image (median green trace strength \(strength)), as is typical after recompression, resizing, or a computational-photography pipeline; block consistency not assessed (low confidence)."
            )
        }

        let reliable = map.reliableBlocks

        let flagged = map.inconsistentBlocks
        guard !flagged.isEmpty else {
            return AnalyzerFinding.clean(
                analyzerID: identifier,
                summary: "CFA demosaicing pattern is consistent across all \(reliable.count) analyzed block(s) (median green trace strength \(strength))."
            )
        }

        let flaggedFraction = Double(flagged.count) / Double(reliable.count)
        let areaScore = min(70, flaggedFraction / Self.saturatingFlaggedFraction * 70)
        func severity(_ block: CFABlockConsistency) -> Double {
            guard threshold > 0, let consistency = block.consistency else { return 0 }
            return max(0, min(1, (threshold - consistency) / threshold))
        }
        let strengthScore = 30 * flagged.reduce(0.0) { $0 + severity($1) } / Double(flagged.count)

        let regions = flagged.map(\.region).sorted { ($0.y, $0.x) < ($1.y, $1.x) }
        let percent = String(format: "%.1f", flaggedFraction * 100)
        var indicators = [Indicator(
            message: "\(flagged.count) of \(reliable.count) analyzed \(blockSize)x\(blockSize) px block(s) (\(percent)%) have a CFA consistency below \(String(format: "%.2f", threshold)) of the image's typical demosaicing trace.",
            weight: areaScore,
            regions: regions
        )]

        for block in flagged.sorted(by: { ($0.consistency ?? 0) < ($1.consistency ?? 0) }).prefix(5) {
            let detail = block.latticeShifted
                ? "its demosaicing pattern sits on the opposite lattice phase from the rest of the image (an offset Bayer grid, or resampled content)"
                : "the demosaicing pattern is missing or much weaker than in the rest of the image"
            indicators.append(Indicator(
                message: "Block at (\(block.region.x),\(block.region.y)) \(block.region.width)x\(block.region.height): CFA consistency \(String(format: "%.2f", block.consistency ?? 0)) (threshold \(String(format: "%.2f", threshold))); \(detail).",
                weight: 30 * severity(block),
                regions: [block.region]
            ))
        }

        return AnalyzerFinding(
            analyzerID: identifier,
            score: areaScore + strengthScore,
            summary: "\(flagged.count) block(s) lack the CFA demosaicing pattern found in the rest of the image, suggesting spliced, resampled, or synthesized regions.",
            indicators: indicators
        )
    }
}
