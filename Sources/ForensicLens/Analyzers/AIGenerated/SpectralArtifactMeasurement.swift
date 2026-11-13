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
}
