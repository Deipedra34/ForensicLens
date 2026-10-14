import Foundation
import ImageDecoding

/// Detects spliced or differently processed regions from inconsistencies
/// in sensor noise, and optionally checks an image against a known
/// camera's PRNU fingerprint.
///
/// Every camera sensor's pixels differ very slightly in sensitivity, and
/// that photo response non-uniformity (PRNU) leaves a faint, fixed noise
/// pattern on every photo the sensor takes. It survives ordinary handling
/// and is unique to the sensor. It's recovered as the noise residual left
/// after denoising (`PRNUResidualExtractor`). This analyzer has two modes:
///
/// - **Local consistency** (always, single image): the residual is split
///   into `blockSize` blocks, and each block's noise signature (level, and
///   correlation structure across neighboring pixels) is compared against
///   the leave-one-out aggregate of every other block
///   (`PRNULocalConsistency`). A block scoring below
///   `correlationThreshold` is flagged. A pasted-in region from another
///   source, or one that was smoothed, resampled, retouched or generated,
///   usually carries noise unlike the rest of the frame's.
/// - **Reference verification** (when a reference fingerprint is supplied,
///   e.g. via `--reference`): the image's residual is correlated against a
///   fingerprint averaged from several images known to come from one
///   camera (`PRNUReferenceFingerprint`), to support or contradict a claim
///   that this image is an unprocessed capture from that camera.
///
/// **Cost.** This is one of the more expensive analyzers. Denoising runs a
/// 4-level wavelet transform with an 8-tap filter, a four-window local
/// variance estimate in every detail subband, and an inverse transform:
/// roughly a few hundred floating-point operations per pixel. Memory is a
/// handful of `Double` planes the size of the working image. Both are
/// bounded by `maximumWorkingDimension`. For local consistency, an image
/// whose larger side exceeds it is box-downsampled by the smallest integer
/// factor that fits. Downsampling averages away part of the per-pixel noise
/// and makes small inconsistent regions harder to see, but it attenuates
/// noise uniformly across the frame, so the *relative* comparison between
/// blocks still holds. Reference verification never downsamples, because
/// that would average away the very per-pixel pattern it matches. It
/// center-crops to the same bound at native resolution instead, and adds
/// three FFTs of the (power-of-two padded) crop. Building the fingerprint
/// costs one residual extraction per reference image, once per run (not
/// once per analyzed image). Large images bypass the tiling layer: every
/// block is compared against an image-wide aggregate, which a per-tile pass
/// would fragment, and the working-resolution cap already bounds cost.
///
/// **Limitations.** PRNU is weak in images that were heavily JPEG
/// compressed, resized, or passed through social media, all of which
/// destroy most of the pattern. It's also weak in dark, saturated or
/// heavily textured areas, where content leaks into the residual and masks
/// the noise. Blocks need to be reasonably large (64px by default) for a
/// stable noise signature. Clipped blocks are skipped. An image with no
/// measurable noise at all (synthetic, flat, or heavily denoised) gets a
/// low-confidence "not assessed" result instead of a guess.
public struct PRNUAnalyzer: Analyzer {
    public let identifier = "prnu"
    public let displayName = "PRNU Sensor Noise Analysis"

    /// The reference fingerprint to verify against, if any.
    public let reference: PRNUReferenceFingerprint?

    /// Smallest block size accepted; smaller config values are raised to
    /// this. Below about 16px a block has too few residual samples for a
    /// stable noise signature.
    static let minimumBlockSize = 16

    /// Smallest `maximumWorkingDimension` accepted.
    static let minimumWorkingDimension = 64

    /// Fewest usable (non-clipped) blocks for a meaningful leave-one-out
    /// comparison.
    static let minimumReliableBlocks = 4

    /// Median residual standard deviation, in gray levels, below which an
    /// image is treated as carrying no measurable sensor noise. Well under
    /// the ~0.29 that 8-bit rounding alone leaves on any non-flat content.
    static let minimumMeasurableNoise = 0.05

    /// The share of analyzed blocks flagged at which the area part of the
    /// score saturates.
    private static let saturatingFlaggedFraction = 0.05

    /// Score for a confident fingerprint mismatch: "suspicious", not
    /// "likely manipulated". A mismatch says the image isn't an untouched
    /// capture from the reference camera, which could also mean an honest
    /// resize or recompression, not necessarily a forgery.
    private static let mismatchScore = 60.0

    public init(reference: PRNUReferenceFingerprint? = nil) {
        self.reference = reference
    }

    public func analyze(_ image: ImageData, config: ForensicLensConfig) throws -> AnalyzerFinding {
        guard let buffer = image.pixels else {
            throw AnalyzerError.unsupportedInput("PRNU analysis requires decoded pixel data, but this image has none.")
        }

        let settings = config.prnu
        let local = localEvidence(buffer, settings: settings)
        let camera = referenceEvidence(buffer, settings: settings)

        let summary = [local.summary, camera?.summary ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
        return AnalyzerFinding(
            analyzerID: identifier,
            score: max(local.score, camera?.score ?? 0),
            summary: summary,
            indicators: local.indicators + (camera?.indicators ?? [])
        )
    }

    /// The integer factor local consistency downsamples a
    /// `width` x `height` image by, so its larger side fits within
    /// `maximumWorkingDimension`.
    static func workingScale(width: Int, height: Int, maximumWorkingDimension: Int) -> Int {
        let cap = max(minimumWorkingDimension, maximumWorkingDimension)
        let larger = max(width, height)
        return max(1, (larger + cap - 1) / cap)
    }

    /// The local consistency map for `buffer`, or `nil` if the image is too
    /// small to hold `minimumReliableBlocks` blocks. Exposed (rather than
    /// only the final finding) so tests and library callers can inspect the
    /// full per-block heat map.
    static func consistencyMap(for buffer: PixelBuffer, settings: ForensicLensConfig.PRNUConfig) -> PRNUConsistencyMap? {
        let blockSize = max(minimumBlockSize, settings.blockSize)
        let threshold = min(1, max(0, settings.correlationThreshold))
        let scale = workingScale(width: buffer.width, height: buffer.height, maximumWorkingDimension: settings.maximumWorkingDimension)
        let workingWidth = buffer.width / scale
        let workingHeight = buffer.height / scale
        guard (workingWidth / blockSize) * (workingHeight / blockSize) >= minimumReliableBlocks else { return nil }

        let luma = PRNUPlane.luminance(of: buffer).downsampled(by: scale)
        let residual = PRNUResidualExtractor.residual(of: luma)
        return PRNULocalConsistency.map(
            residual: residual,
            luma: luma,
            blockSize: blockSize,
            threshold: threshold,
            scale: scale,
            originalWidth: buffer.width,
            originalHeight: buffer.height
        )
    }

    // MARK: - Local consistency evidence

    private struct Evidence {
        let score: Double
        let summary: String
        let indicators: [Indicator]
    }

    private func localEvidence(_ buffer: PixelBuffer, settings: ForensicLensConfig.PRNUConfig) -> Evidence {
        let blockSize = max(Self.minimumBlockSize, settings.blockSize)
        let threshold = min(1, max(0, settings.correlationThreshold))
        let scale = Self.workingScale(width: buffer.width, height: buffer.height, maximumWorkingDimension: settings.maximumWorkingDimension)
        let resolutionNote = scale > 1
            ? " (Analyzed at 1/\(scale) resolution, \(buffer.width / scale)x\(buffer.height / scale), to bound cost.)"
            : ""

        guard let map = Self.consistencyMap(for: buffer, settings: settings) else {
            return Evidence(
                score: 0,
                summary: "Image is too small for a sensor-noise consistency check: it needs at least \(Self.minimumReliableBlocks) blocks of \(blockSize)x\(blockSize) px at working resolution.\(resolutionNote)",
                indicators: []
            )
        }

        let reliable = map.reliableBlocks
        guard reliable.count >= Self.minimumReliableBlocks else {
            return Evidence(
                score: 0,
                summary: "Only \(reliable.count) of \(map.blocks.count) block(s) aren't clipped to pure black or white, too few to compare; sensor-noise consistency not assessed (low confidence).\(resolutionNote)",
                indicators: []
            )
        }
        guard map.aggregateNoiseLevel >= Self.minimumMeasurableNoise else {
            return Evidence(
                score: 0,
                summary: "No measurable sensor noise (median residual \(String(format: "%.3f", map.aggregateNoiseLevel)) gray levels), as in a synthetic, flat or heavily denoised image; sensor-noise consistency not assessed (low confidence).\(resolutionNote)",
                indicators: []
            )
        }

        let flagged = map.inconsistentBlocks
        guard !flagged.isEmpty else {
            return Evidence(
                score: 0,
                summary: "Sensor noise is consistent across all \(reliable.count) analyzed block(s).\(resolutionNote)",
                indicators: []
            )
        }

        let flaggedFraction = Double(flagged.count) / Double(reliable.count)
        let areaScore = min(70, flaggedFraction / Self.saturatingFlaggedFraction * 70)
        func severity(_ block: PRNUBlockConsistency) -> Double {
            guard threshold > 0, let consistency = block.consistency else { return 0 }
            return max(0, min(1, (threshold - consistency) / threshold))
        }
        let strengthScore = 30 * flagged.reduce(0.0) { $0 + severity($1) } / Double(flagged.count)

        let regions = flagged.map(\.region).sorted { ($0.y, $0.x) < ($1.y, $1.x) }
        let percent = String(format: "%.1f", flaggedFraction * 100)
        let side = blockSize * scale
        var indicators = [Indicator(
            message: "\(flagged.count) of \(reliable.count) analyzed \(side)x\(side) px block(s) (\(percent)%) have a sensor-noise consistency score below \(String(format: "%.2f", threshold)).",
            weight: areaScore,
            regions: regions
        )]

        let worst = flagged.sorted { ($0.consistency ?? 0) < ($1.consistency ?? 0) }.prefix(5)
        for block in worst {
            var message = "Block at (\(block.region.x),\(block.region.y)) \(block.region.width)x\(block.region.height): noise consistency \(String(format: "%.2f", block.consistency ?? 0)) (threshold \(String(format: "%.2f", threshold)))"
            if let ratio = block.noiseLevelRatio {
                message += ", noise level \(String(format: "%.2f", ratio))x the rest of the image"
                if ratio < 0.25 {
                    message += " (almost no sensor noise)"
                }
            }
            indicators.append(Indicator(message: message + ".", weight: 30 * severity(block), regions: [block.region]))
        }

        return Evidence(
            score: areaScore + strengthScore,
            summary: "\(flagged.count) block(s) carry sensor noise inconsistent with the rest of the image, suggesting spliced, retouched or differently processed regions.\(resolutionNote)",
            indicators: indicators
        )
    }

    // MARK: - Reference verification evidence

    private func referenceEvidence(_ buffer: PixelBuffer, settings: ForensicLensConfig.PRNUConfig) -> Evidence? {
        guard let reference else {
            guard let folder = settings.referenceFolder else { return nil }
            return Evidence(
                score: 0,
                summary: "",
                indicators: [Indicator(
                    message: "PRNU reference folder \"\(folder)\" is configured, but no fingerprint was loaded into this analyzer, so camera verification was skipped. Load it with PRNUReferenceFingerprint.loadIfConfigured and pass it to ForensicLensEngine(config:prnuReference:).",
                    weight: 0
                )]
            )
        }

        let verification = reference.verify(buffer)
        let count = verification.referenceImageCount
        let source = "the reference fingerprint built from \(count) image(s)"
            + (verification.isLowConfidence ? " (low confidence: fewer than \(PRNUReferenceFingerprint.recommendedImageCount) reference images)" : "")
        let pce = String(format: "%.1f", verification.peakToCorrelationEnergy ?? 0)
        let rho = String(format: "%.4f", verification.peakCorrelation ?? 0)
        let threshold = String(format: "%.0f", PRNUReferenceFingerprint.matchThreshold)

        switch verification.outcome {
        case .match:
            return Evidence(
                score: 0,
                summary: "Sensor noise matches \(source) (PCE \(pce), threshold \(threshold)), supporting that it was taken by the reference camera.",
                indicators: [Indicator(
                    message: "Reference camera check: PCE \(pce) at or above \(threshold), correlation \(rho); the reference camera's sensor pattern is present.",
                    weight: 0
                )]
            )
        case .mismatch:
            let confidence = min(1, Double(count) / Double(PRNUReferenceFingerprint.recommendedImageCount))
            let score = Self.mismatchScore * confidence
            return Evidence(
                score: score,
                summary: "Sensor noise does not match \(source) (PCE \(pce), below \(threshold)): either a different camera took it, or it was resized, cropped or heavily processed after capture.",
                indicators: [Indicator(
                    message: "Reference camera check: PCE \(pce) below \(threshold), correlation \(rho); the reference camera's sensor pattern was not found in the analyzed region.",
                    weight: score,
                    regions: [reference.analysisRegion]
                )]
            )
        case .dimensionMismatch:
            return Evidence(
                score: 0,
                summary: "Reference camera check skipped: the image is \(buffer.width)x\(buffer.height), but the reference images are \(reference.imageWidth)x\(reference.imageHeight). A PRNU match needs the same native resolution and orientation.",
                indicators: []
            )
        case .noMeasurableNoise:
            return Evidence(
                score: 0,
                summary: "Reference camera check inconclusive: the image has no measurable noise residual to correlate.",
                indicators: []
            )
        }
    }
}
