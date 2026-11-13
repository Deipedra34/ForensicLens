import Foundation

/// What `SpectralArtifactDetector` found in one image: how far each
/// upsampling-lattice frequency stands above its local spectral
/// background.
struct SpectralArtifactMeasurement: Sendable, Equatable {
    enum Status: Sendable, Equatable {
        /// The crop was analyzed and `peaks` holds one entry per lattice
        /// frequency.
        case measured
        /// Nothing could be measured, for the reason given (too small,
        /// flat). `peaks` is empty.
        case insufficientData(String)
    }

    /// One lattice frequency's measurement.
    struct LatticePeak: Sendable, Equatable {
        let bin: SpectralArtifactDetector.Bin
        /// The shortest upsampling period, in pixels, whose lattice
        /// contains this bin.
        let period: Int
        /// The strongest power within one bin of the lattice frequency,
        /// divided by the median power of the ring of bins around it. About
        /// 1 to 3 for noise and natural texture; orders of magnitude more
        /// for a genuinely periodic pattern.
        let ratio: Double
    }

    let status: Status

    /// The centered crop that was analyzed, in the image's pixel
    /// coordinates. `nil` when nothing was measured.
    let analyzedRegion: Region?

    /// Side length of the analyzed crop (and its spectrum), or 0.
    let cropSize: Int

    let peaks: [LatticePeak]

    static func insufficientData(_ reason: String) -> SpectralArtifactMeasurement {
        SpectralArtifactMeasurement(status: .insufficientData(reason), analyzedRegion: nil, cropSize: 0, peaks: [])
    }

    var isMeasured: Bool { status == .measured }

    /// The lattice frequency with the highest ratio, if any were measured.
    var strongestPeak: LatticePeak? {
        peaks.max { $0.ratio < $1.ratio }
    }

    // MARK: - Scoring

    /// The peak-to-background ratio a lattice frequency must reach to count
    /// as a periodic artifact, for a `sensitivity` from 0 to 1 (clamped):
    /// `10^(2 - sensitivity)`, so 100 at sensitivity 0, about 32 at the
    /// default 0.5, and 10 at 1.
    ///
    /// Power in a noise-like spectral bin is roughly exponentially
    /// distributed, so the strongest of the ~9 bins around one lattice
    /// frequency reaches 10x the ring median by chance about once in a few
    /// hundred candidates, and 30x essentially never. Sensitivities near 1
    /// therefore start flagging chance fluctuations on noisy images.
    static func peakRatioThreshold(sensitivity: Double) -> Double {
        let clamped = min(1, max(0, sensitivity.isFinite ? sensitivity : 0.5))
        return pow(10, 2 - clamped)
    }

    /// Ratio, as a multiple of the threshold, at which the score saturates:
    /// a peak 30x past the threshold scores 1.
    static let saturatingRatioMultiple = 30.0

    /// The lattice frequencies at or above `threshold`, strongest first.
    func flaggedPeaks(threshold: Double) -> [LatticePeak] {
        peaks.filter { $0.ratio >= threshold }.sorted { $0.ratio > $1.ratio }
    }

    /// The spectral-artifact signal, 0 to 1, at `sensitivity`.
    ///
    /// 0 when nothing was measured or no lattice frequency reaches the
    /// threshold, so that ordinary images contribute exactly nothing. A
    /// peak just at the threshold scores 0.5, and the score rises with the
    /// logarithm of how far the strongest peak exceeds it, reaching 1 at
    /// `saturatingRatioMultiple` times the threshold. Starting at 0.5
    /// rather than 0 reflects that clearing the threshold is already
    /// unlikely by chance; the log scale reflects that a peak 10x past the
    /// threshold isn't 10x the evidence.
    func artifactScore(sensitivity: Double) -> Double {
        let threshold = Self.peakRatioThreshold(sensitivity: sensitivity)
        guard isMeasured, let strongest = strongestPeak, strongest.ratio >= threshold else { return 0 }
        let excess = log10(strongest.ratio / threshold) / log10(Self.saturatingRatioMultiple)
        return min(1, 0.5 + 0.5 * excess)
    }
}
