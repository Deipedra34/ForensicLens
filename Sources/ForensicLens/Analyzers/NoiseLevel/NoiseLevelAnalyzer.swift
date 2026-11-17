import Foundation
import ImageDecoding

/// Flags regions whose local noise level differs from the rest of the
/// image: a fast, lightweight complement to `PRNUAnalyzer`.
///
/// A photo taken in one exposure on one sensor has roughly the same noise
/// level across most of its area. A region spliced in from another photo,
/// smoothed or denoised, painted, or rendered usually doesn't. The image is
/// split into `blockSize` blocks; each block's noise level is estimated
/// from a cheap high-pass residual (`NoiseResidual`, `NoiseVariance`) and
/// compared with the median over all blocks (`NoiseDeviation`). Blocks well
/// below it are flagged as **too smooth** (denoised, blurred, synthetic, or
/// from a cleaner source); blocks well above it as **too noisy** (from a
/// noisier source, or with added noise). The two are reported separately
/// because they point at different kinds of edit.
///
/// **How it relates to PRNU.** PRNU analysis looks for one specific
/// sensor's fixed noise *pattern*, which takes a wavelet denoiser and
/// correlation statistics to recover. This check only measures how *much*
/// noise each block has. It can't tell two cameras with similar noise
/// apart, which PRNU can, but it also catches edits PRNU can miss (a
/// region with plenty of noise, just at the wrong level), and it costs a
/// small fraction as much: one nine-tap filter pass and a median per
/// block, linear in pixel count, with memory of one block-sized plane at a
/// time. It never downsamples. That makes it suitable to run first, or to
/// leave on when the heavier detectors (PRNU, CFA, clone detection, JPEG
/// ghosts) are disabled for speed. It's a pre-check and a supporting
/// signal, not a replacement for PRNU.
///
/// **Limitations.** Noise level varies legitimately within one untouched
/// photo, so this check is more prone to false positives than PRNU:
///
/// - **Exposure.** Shot noise grows with brightness, so a high-dynamic-range
///   scene's shadows are less noisy than its highlights. Deviations whose
///   size brightness alone predicts are reported but down-weighted
///   (`NoiseDeviation.exposureExplained`), and an image whose blocks vary
///   widely widens the thresholds (`NoiseDeviation.cutoffs`), but a strong
///   enough exposure difference can still be flagged.
/// - **Texture and edges** leak into the residual and read as noise.
///   The median-based estimate tolerates some, but a block of fine texture
///   (foliage, fabric, gravel) can look too noisy.
/// - **Defocus and motion blur** smooth noise-like detail along with content
///   and can look too smooth, as can clipped or nearly clipped areas (fully
///   clipped blocks are skipped).
/// - **Processing** such as JPEG compression and in-camera noise reduction
///   change noise levels unevenly with content.
///
/// Its score is capped below the other detectors' maximum for that reason.
public struct NoiseLevelAnalyzer: Analyzer {
    public let identifier = "noiselevel"
    public let displayName = "Noise-Level Consistency"

    /// Smallest block size accepted; smaller config values are raised to
    /// this. Below it a block has too few residual samples for a stable
    /// median.
    static let minimumBlockSize = 16

    /// Fewest measured blocks for a meaningful comparison.
    static let minimumReliableBlocks = 4

    /// The share of measured blocks flagged at which the area part of the
    /// score saturates (as for CFA and PRNU).
    private static let saturatingFlaggedFraction = 0.05

    /// Score caps: area and severity together top out at 80, below what the
    /// more specific detectors can reach, since this one is more prone to
    /// false positives.
    private static let maximumAreaScore = 55.0
    private static let maximumSeverityScore = 25.0

    /// How much a block whose deviation exposure explains counts, relative
    /// to one it doesn't.
    static let exposureExplainedWeight = 0.25

    public init() {}

    /// `blockSize` from config, raised to at least `minimumBlockSize`.
    static func effectiveBlockSize(_ configured: Int) -> Int {
        max(minimumBlockSize, configured)
    }

    /// The noise-level map for `buffer`, or `nil` if the image is too small
    /// to hold `minimumReliableBlocks` blocks. Exposed so tests and library
    /// callers can inspect the per-block heat map directly.
    public static func noiseLevelMap(for buffer: PixelBuffer, settings: ForensicLensConfig.NoiseLevelConfig) -> NoiseLevelMap? {
        let blockSize = effectiveBlockSize(settings.blockSize)
        guard (buffer.width / blockSize) * (buffer.height / blockSize) >= minimumReliableBlocks else { return nil }
        return NoiseLevelEstimation.map(buffer, blockSize: blockSize, smoothThreshold: settings.smoothThreshold, noisyThreshold: settings.noisyThreshold)
    }

    public func analyze(_ image: ImageData, config: ForensicLensConfig) throws -> AnalyzerFinding {
        guard let buffer = image.pixels else {
            throw AnalyzerError.unsupportedInput("Noise-level analysis requires decoded pixel data, but this image has none.")
        }

        let settings = config.noiseLevel
        let blockSize = Self.effectiveBlockSize(settings.blockSize)
        guard let map = Self.noiseLevelMap(for: buffer, settings: settings) else {
            return AnalyzerFinding.clean(analyzerID: identifier, summary: "Image is too small for a noise-level consistency check: it needs at least \(Self.minimumReliableBlocks) blocks of \(blockSize)x\(blockSize) px; not assessed (low confidence).")
        }
        guard map.measuredBlockCount >= Self.minimumReliableBlocks else {
            return AnalyzerFinding.clean(
                analyzerID: identifier,
                summary: "Only \(map.measuredBlockCount) of \(map.blocks.count) block(s) are not clipped to black or white; noise-level consistency not assessed (low confidence)."
            )
        }
        let typical = String(format: "%.2f", map.typicalSigma)
        guard map.noiseMeasurable else {
            return AnalyzerFinding.clean(
                analyzerID: identifier,
                summary: "No measurable noise (typical noise level \(typical) gray levels): the image is uniform, synthetic, or heavily denoised, so there's no noise level to compare blocks against; not assessed (low confidence)."
            )
        }

        let reliable = map.reliableBlocks
        let flagged = map.flaggedBlocks
        guard !flagged.isEmpty else {
            return AnalyzerFinding.clean(
                analyzerID: identifier,
                summary: "Noise level is consistent across all \(reliable.count) analyzed block(s) (typical noise \(typical) gray levels)."
            )
        }

        let cutoffs = NoiseDeviation.Cutoffs(lower: map.smoothCutoff, upper: map.noisyCutoff)
        func weight(_ block: NoiseBlockLevel) -> Double {
            block.exposureExplained ? Self.exposureExplainedWeight : 1
        }
        func severity(_ block: NoiseBlockLevel) -> Double {
            guard let ratio = block.ratio, let direction = block.direction else { return 0 }
            return NoiseDeviation.severity(ratio: ratio, direction: direction, cutoffs: cutoffs)
        }

        let totalWeight = flagged.reduce(0.0) { $0 + weight($1) }
        let areaScore = min(Self.maximumAreaScore, totalWeight / Double(reliable.count) / Self.saturatingFlaggedFraction * Self.maximumAreaScore)
        let severityScore = Self.maximumSeverityScore * flagged.reduce(0.0) { $0 + severity($1) * weight($1) } / totalWeight

        var indicators: [Indicator] = []
        for direction in [NoiseDeviationDirection.tooSmooth, .tooNoisy] {
            let group = flagged.filter { $0.direction == direction }
            guard !group.isEmpty else { continue }
            let groupWeight = group.reduce(0.0) { $0 + weight($1) }
            let explained = group.filter(\.exposureExplained).count
            let percent = String(format: "%.1f", Double(group.count) / Double(reliable.count) * 100)
            let description = direction == .tooSmooth
                ? "have less than \(String(format: "%.2f", cutoffs.lower))x the image's typical noise level (too smooth: denoised, blurred, synthetic, or from a cleaner source)"
                : "have more than \(String(format: "%.2f", cutoffs.upper))x the image's typical noise level (too noisy: from a noisier source, or with added noise)"
            var message = "\(group.count) of \(reliable.count) analyzed \(blockSize)x\(blockSize) px block(s) (\(percent)%) \(description)."
            if explained > 0 {
                message += " \(explained) of them match what exposure alone predicts (\(direction == .tooSmooth ? "darker" : "brighter") than typical), so they count for less."
            }
            indicators.append(Indicator(
                message: message,
                weight: areaScore * groupWeight / totalWeight,
                regions: group.map(\.region).sorted { ($0.y, $0.x) < ($1.y, $1.x) }
            ))
        }

        for block in flagged.sorted(by: { severity($0) * weight($0) > severity($1) * weight($1) }).prefix(5) {
            let ratio = String(format: "%.2f", block.ratio ?? 0)
            let sigma = String(format: "%.2f", block.sigma ?? 0)
            let detail = block.direction == .tooSmooth ? "too smooth" : "too noisy"
            var message = "Block at (\(block.region.x),\(block.region.y)) \(block.region.width)x\(block.region.height): \(detail), noise \(sigma) gray levels (\(ratio)x the image's typical \(typical))."
            if block.exposureExplained, let luma = block.meanLuma {
                message += " Its brightness (\(String(format: "%.0f", luma)) vs typical \(String(format: "%.0f", map.typicalLuma))) could account for this on its own."
            }
            indicators.append(Indicator(
                message: message,
                weight: Self.maximumSeverityScore * severity(block) * weight(block),
                regions: [block.region]
            ))
        }

        let smoothCount = flagged.filter { $0.direction == .tooSmooth }.count
        let noisyCount = flagged.count - smoothCount
        var parts: [String] = []
        if smoothCount > 0 { parts.append("\(smoothCount) too smooth") }
        if noisyCount > 0 { parts.append("\(noisyCount) too noisy") }
        return AnalyzerFinding(
            analyzerID: identifier,
            score: areaScore + severityScore,
            summary: "\(flagged.count) block(s) have a noise level unlike the rest of the image (\(parts.joined(separator: ", "))), a supporting sign of spliced, smoothed, or differently sourced regions.",
            indicators: indicators
        )
    }
}
