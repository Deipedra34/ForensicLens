import Foundation
import ImageDecoding

/// Flags images that show statistical signals consistent with having been
/// produced by a generative model (a GAN or diffusion model) rather than
/// captured by a camera.
///
/// Every other pixel analyzer in this package assumes a real photograph
/// that may have been *edited*, and looks for the edit. This one asks a
/// different question: whether the image may not be a photograph at all.
/// It combines two classical signal-analysis checks, each its own small,
/// separately tested unit:
///
/// - **Spectral upsampling artifacts** (`SpectralArtifactDetector`):
///   sharp peaks at the frequencies a 2x, 4x or 8x upsampling layer's
///   periodic pattern produces, in the high-pass spectrum of a centered
///   crop.
/// - **Global PRNU absence** (`PRNUGlobalPresence`): whether any coherent,
///   camera-like sensor noise shows up across the image's extent. This
///   complements `PRNUAnalyzer`'s local consistency check, which compares
///   blocks of a presumed-real photo against each other and so, by design,
///   reports an image that lacks sensor noise *everywhere* as consistent.
///
/// The two signals are combined by `AIGenerationScore` under a configurable
/// rule (by default, both must agree) into a score of up to 75.
///
/// **Limitations, stated plainly.** This is not a trained classifier. It
/// detects two specific statistical traces some generators leave, and so:
///
/// - it **under-detects** newer and less common generative models, many of
///   which avoid checkerboard artifacts or produce natural-looking noise;
/// - its accuracy will likely **degrade as generators evolve** to reduce
///   these traces (better upsampling, anti-aliased decoders, synthetic
///   noise injection) and when images are resized, recompressed or
///   filtered after generation, which erases both traces;
/// - each signal has **innocent explanations** on its own (JPEG grids,
///   demosaicing, resampling and periodic scenes for the spectral one;
///   screenshots, graphics and heavily processed photos for missing sensor
///   noise), which is why both must agree by default.
///
/// Every result is worded as "signals consistent with AI generation", never
/// as a determination that an image is or isn't generated.
///
/// **Cost.** One forward FFT of a crop of at most 512x512, plus one PRNU
/// residual extraction at PRNU's working resolution (the same cost as the
/// PRNU analyzer's local check). Runs outside the tiling layer: both
/// signals are image-wide.
public struct AIGeneratedImageAnalyzer: Analyzer {
    public let identifier = "aigenerated"
    public let displayName = "AI-Generated Image Signals"

    public init() {}

    public func analyze(_ image: ImageData, config: ForensicLensConfig) throws -> AnalyzerFinding {
        guard let buffer = image.pixels else {
            throw AnalyzerError.unsupportedInput("AI-generated image detection requires decoded pixel data, but this image has none.")
        }
        let settings = config.aiGenerated
        let spectral = SpectralArtifactDetector.measure(PRNUPlane.luminance(of: buffer))
        let presence = PRNUGlobalPresence.assess(buffer, settings: config.prnu)
        return Self.finding(spectral: spectral, presence: presence, settings: settings, identifier: identifier)
    }

    /// Builds the finding from already-computed measurements. Separate from
    /// `analyze` so the wording and scoring can be tested without images.
    static func finding(
        spectral: SpectralArtifactMeasurement,
        presence: PRNUPresenceAssessment,
        settings: ForensicLensConfig.AIGeneratedConfig,
        identifier: String = "aigenerated"
    ) -> AnalyzerFinding {
        let threshold = SpectralArtifactMeasurement.peakRatioThreshold(sensitivity: settings.spectralSensitivity)
        let coverageThreshold = min(1, max(0, settings.prnuAbsenceThreshold.isFinite ? settings.prnuAbsenceThreshold : 0))
        let s = spectral.artifactScore(sensitivity: settings.spectralSensitivity)
        let a = presence.absenceSignal(threshold: coverageThreshold)
        let likelihood = AIGenerationScore.likelihood(spectral: s, prnuAbsence: a, singleSignalWeight: settings.singleSignalWeight)
        let score = AIGenerationScore.findingScore(likelihood: likelihood)

        let indicators = [
            spectralIndicator(spectral, threshold: threshold, signal: s),
            presenceIndicator(presence, threshold: coverageThreshold, signal: a)
        ]

        let summary: String
        if !spectral.isMeasured && !presence.isAssessed {
            summary = "Not assessed (low confidence): the image is too small, flat or clipped for either the spectral or the sensor-noise check."
        } else if likelihood > 0 {
            summary = "Signals consistent with AI generation (combined likelihood \(percent(likelihood))): \(describe(s: s, a: a)). A statistical indication from classical signal analysis, not a determination that the image was generated."
        } else if s > 0 || a > 0 {
            summary = "No combination of signals consistent with AI generation: only \(s > 0 ? "spectral upsampling artifacts" : "an absence of camera sensor noise") was found, and on its own that is common in ordinary images (singleSignalWeight \(String(format: "%.2f", settings.singleSignalWeight)))."
        } else {
            let caveat = (spectral.isMeasured && presence.isAssessed) ? "" : " Only one of the two checks could run (low confidence)."
            summary = "No signals consistent with AI generation found: no upsampling-lattice spectral peaks, and camera-like sensor noise is present.\(caveat)"
        }

        return AnalyzerFinding(analyzerID: identifier, score: score, summary: summary, indicators: indicators)
    }

    // MARK: - Indicators

    private static func spectralIndicator(_ spectral: SpectralArtifactMeasurement, threshold: Double, signal: Double) -> Indicator {
        guard case .measured = spectral.status, let strongest = spectral.strongestPeak else {
            if case .insufficientData(let reason) = spectral.status {
                return Indicator(message: "Spectral artifact check not run: \(reason).", weight: 0)
            }
            return Indicator(message: "Spectral artifact check found no lattice frequencies to measure.", weight: 0)
        }
        let regions = spectral.analyzedRegion.map { [$0] } ?? []
        let flagged = spectral.flaggedPeaks(threshold: threshold)
        let crop = "\(spectral.cropSize)x\(spectral.cropSize) px"
        guard !flagged.isEmpty else {
            return Indicator(
                message: "Spectral artifact check (\(crop) crop): no upsampling-lattice frequency stands out; strongest peak \(ratio(strongest.ratio)) its local background, below the \(ratio(threshold)) threshold.",
                weight: 0
            )
        }
        let periods = Set(flagged.map(\.period)).sorted().map { "\($0)" }.joined(separator: "/")
        return Indicator(
            message: "Spectral artifact check (\(crop) crop): \(flagged.count) upsampling-lattice frequenc\(flagged.count == 1 ? "y" : "ies") (period \(periods) px) stand above the \(ratio(threshold)) threshold; strongest at bin (\(strongest.bin.u),\(strongest.bin.v)), \(ratio(strongest.ratio)) its local background. Consistent with a generator's upsampling pattern, though JPEG grids, demosaicing and resampling can also produce such peaks.",
            weight: AIGenerationScore.findingScore(likelihood: signal),
            regions: regions
        )
    }

    private static func presenceIndicator(_ presence: PRNUPresenceAssessment, threshold: Double, signal: Double) -> Indicator {
        guard presence.isAssessed else {
            if case .insufficientData(let reason) = presence.status {
                return Indicator(message: "Sensor-noise presence not assessed: \(reason).", weight: 0)
            }
            return Indicator(message: "Sensor-noise presence not assessed.", weight: 0)
        }
        let counts = "\(presence.sensorLikeBlockCount) of \(presence.reliableBlockCount) analyzed block(s) (\(percent(presence.coverage))) carry camera-like sensor noise (median residual \(String(format: "%.2f", presence.medianNoiseLevel)) gray levels)"
        guard signal > 0 else {
            return Indicator(message: "Sensor-noise presence: \(counts), at or above the \(percent(threshold)) threshold, as expected of a camera image.", weight: 0)
        }
        return Indicator(
            message: "Sensor-noise presence: only \(counts), below the \(percent(threshold)) threshold. No coherent camera sensor-noise fingerprint across the image, consistent with synthetic generation, though screenshots, graphics and heavily processed photos lack one too.",
            weight: AIGenerationScore.findingScore(likelihood: signal)
        )
    }

    // MARK: - Formatting

    private static func describe(s: Double, a: Double) -> String {
        var parts: [String] = []
        if s > 0 { parts.append("spectral upsampling artifacts (signal \(String(format: "%.2f", s)))") }
        if a > 0 { parts.append("no coherent camera sensor-noise fingerprint (signal \(String(format: "%.2f", a)))") }
        return parts.joined(separator: " and ")
    }

    private static func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value * 100)
    }

    private static func ratio(_ value: Double) -> String {
        value >= 1000 ? String(format: "%.0fx", value) : String(format: "%.1fx", value)
    }
}
