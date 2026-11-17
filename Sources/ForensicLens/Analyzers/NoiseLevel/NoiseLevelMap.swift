/// One block of a `NoiseLevelMap`.
public struct NoiseBlockLevel: Sendable, Equatable {
    public enum Status: String, Sendable, Equatable {
        /// The block's noise level is in line with the rest of the image.
        case consistent
        /// Noticeably less noise than the rest of the image.
        case tooSmooth
        /// Noticeably more noise than the rest of the image.
        case tooNoisy
        /// The block wasn't judged: mostly clipped to black or white, where
        /// a sensor records no noise to measure.
        case unreliable
    }

    /// The block's area, in image pixel coordinates.
    public let region: Region

    public let status: Status

    /// The block's estimated noise standard deviation, in gray levels
    /// (`NoiseVariance.robustSigma` of its luma residual). `nil` for an
    /// unreliable block.
    public let sigma: Double?

    /// `sigma` as a fraction of the image's typical noise level: about 1
    /// for an ordinary block. `nil` for an unreliable block, or when the
    /// image has no measurable noise to compare against.
    public let ratio: Double?

    /// The block's mean luma, 0...255. `nil` for an unreliable block.
    public let meanLuma: Double?

    /// For a flagged block: whether its brightness alone accounts for the
    /// deviation, as with an untouched photo's shadows and highlights (see
    /// `NoiseDeviation.exposureExplained`). Always `false` otherwise.
    public let exposureExplained: Bool

    /// The direction a flagged block deviates in, `nil` for any other.
    public var direction: NoiseDeviationDirection? {
        switch status {
        case .tooSmooth: return .tooSmooth
        case .tooNoisy: return .tooNoisy
        case .consistent, .unreliable: return nil
        }
    }

    public init(region: Region, status: Status, sigma: Double?, ratio: Double?, meanLuma: Double?, exposureExplained: Bool) {
        self.region = region
        self.status = status
        self.sigma = sigma
        self.ratio = ratio
        self.meanLuma = meanLuma
        self.exposureExplained = exposureExplained
    }
}

/// The per-block result of the noise-level consistency check: a coarse
/// heat map of each block's noise level relative to the rest of the image,
/// in row-major block order, the same shape as the CFA and PRNU maps.
public struct NoiseLevelMap: Sendable, Equatable {
    public let columns: Int
    public let rows: Int
    public let blocks: [NoiseBlockLevel]

    /// The image's typical noise level: the median block `sigma`, in gray
    /// levels. 0 if no block could be measured.
    public let typicalSigma: Double

    /// The median mean luma of the measured blocks.
    public let typicalLuma: Double

    /// The noise ratios outside which blocks were flagged: below
    /// `smoothCutoff` too smooth, above `noisyCutoff` too noisy. These are
    /// the configured thresholds, widened when the image's blocks naturally
    /// vary more (see `NoiseDeviation.cutoffs`). 0 when no block was judged.
    public let smoothCutoff: Double
    public let noisyCutoff: Double

    /// How many blocks weren't mostly clipped, so had a noise level to
    /// measure.
    public var measuredBlockCount: Int {
        blocks.filter { $0.sigma != nil }.count
    }

    /// Whether the image carries enough noise for blocks to be compared at
    /// all. A uniform-color, synthetic, or fully denoised image doesn't,
    /// and no block is judged.
    public var noiseMeasurable: Bool {
        typicalSigma >= NoiseLevelEstimation.minimumMeasurableNoise
    }

    public var reliableBlocks: [NoiseBlockLevel] {
        blocks.filter { $0.status != .unreliable }
    }

    /// Every block flagged in either direction.
    public var flaggedBlocks: [NoiseBlockLevel] {
        blocks.filter { $0.direction != nil }
    }

    public init(columns: Int, rows: Int, blocks: [NoiseBlockLevel], typicalSigma: Double, typicalLuma: Double, smoothCutoff: Double = 0, noisyCutoff: Double = 0) {
        self.columns = columns
        self.rows = rows
        self.blocks = blocks
        self.typicalSigma = typicalSigma
        self.typicalLuma = typicalLuma
        self.smoothCutoff = smoothCutoff
        self.noisyCutoff = noisyCutoff
    }
}
