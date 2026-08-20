/// Typed, per-analyzer configuration loaded from `forensiclens.yaml` at
/// startup.
///
/// Every analyzer gets its own nested config struct with an `enabled` flag,
/// so the CLI (or a library caller) can turn analyzers on and off and tune
/// their thresholds without touching code. `ForensicLensConfig` itself has
/// no logic beyond validation -- the values here are just numbers until an
/// analyzer reads them.
public struct ForensicLensConfig: Codable, Equatable, Sendable {
    /// Settings for `ELAAnalyzer`.
    public struct ELAConfig: Codable, Equatable, Sendable {
        /// Whether ELA runs as part of a combined report.
        public var enabled: Bool

        /// The JPEG-style recompression quality used to generate the
        /// comparison image, from 1 (heavy quantization) to 100 (almost
        /// lossless). Lower values make ELA more sensitive but also noisier
        /// -- see `ELAAnalyzer`'s doc comment for the trade-off.
        public var qualityLevel: Int

        /// A per-pixel luma error above this (0...255) is considered part
        /// of a "hot" region rather than ordinary recompression noise.
        public var errorThreshold: Double

        /// The fraction of the image (0...1) that must fall in hot regions
        /// before ELA treats the image as suspicious rather than just
        /// noting some recompression noise, which every JPEG has.
        public var flaggedRegionFraction: Double

        public init(enabled: Bool, qualityLevel: Int, errorThreshold: Double, flaggedRegionFraction: Double) {
            self.enabled = enabled
            self.qualityLevel = qualityLevel
            self.errorThreshold = errorThreshold
            self.flaggedRegionFraction = flaggedRegionFraction
        }
    }

    /// Settings for `MetadataAnalyzer`.
    public struct MetadataConfig: Codable, Equatable, Sendable {
        /// Whether metadata analysis runs as part of a combined report.
        public var enabled: Bool

        /// Whether the total absence of EXIF data should itself count as an
        /// indicator. Off by default in strict use since plenty of
        /// legitimate images (screenshots, exports, scans) have none.
        public var flagMissingExif: Bool

        /// Substrings (matched case-insensitively) that mark the `Software`
        /// EXIF tag as an editing tool rather than a camera or phone.
        public var suspiciousSoftwareKeywords: [String]

        /// The largest gap, in seconds, allowed between `DateTimeOriginal`
        /// and `DateTime` (last-modified) before it's flagged. A same-day
        /// re-save is normal; a multi-year gap usually isn't.
        public var maxTimestampDriftSeconds: Int

        public init(enabled: Bool, flagMissingExif: Bool, suspiciousSoftwareKeywords: [String], maxTimestampDriftSeconds: Int) {
            self.enabled = enabled
            self.flagMissingExif = flagMissingExif
            self.suspiciousSoftwareKeywords = suspiciousSoftwareKeywords
            self.maxTimestampDriftSeconds = maxTimestampDriftSeconds
        }
    }

    /// Settings for `CloneDetectionAnalyzer`.
    public struct CloneDetectionConfig: Codable, Equatable, Sendable {
        /// Whether copy-move detection runs as part of a combined report.
        public var enabled: Bool

        /// Side length, in pixels, of each comparison block. Smaller blocks
        /// catch smaller cloned regions but cost more comparisons (roughly
        /// quadratic in block count) and are more easily fooled by noise;
        /// larger blocks are faster and more robust but miss small edits.
        public var blockSize: Int

        /// Pixel distance between the top-left corners of consecutive
        /// candidate blocks. A stride smaller than `blockSize` overlaps
        /// blocks, which improves recall at the cost of more comparisons.
        public var blockStride: Int

        /// Blocks with pixel variance below this are treated as flat
        /// (sky, a wall, a solid background) and skipped entirely. Flat
        /// regions are trivially "identical" to each other and would
        /// otherwise dominate the match list with meaningless pairs.
        public var minimumBlockVariance: Double

        /// Maximum feature-space distance between two blocks' descriptors
        /// for them to be considered a clone match. Lower is stricter.
        public var similarityThreshold: Double

        /// Minimum pixel distance required between two matched blocks'
        /// positions. Prevents a block from trivially "matching" its own
        /// near neighbors under overlap.
        public var minimumBlockDistance: Int

        public init(enabled: Bool, blockSize: Int, blockStride: Int, minimumBlockVariance: Double, similarityThreshold: Double, minimumBlockDistance: Int) {
            self.enabled = enabled
            self.blockSize = blockSize
            self.blockStride = blockStride
            self.minimumBlockVariance = minimumBlockVariance
            self.similarityThreshold = similarityThreshold
            self.minimumBlockDistance = minimumBlockDistance
        }
    }

    public var ela: ELAConfig
    public var metadata: MetadataConfig
    public var cloneDetection: CloneDetectionConfig

    public init(ela: ELAConfig, metadata: MetadataConfig, cloneDetection: CloneDetectionConfig) {
        self.ela = ela
        self.metadata = metadata
        self.cloneDetection = cloneDetection
    }

    /// Reasonable defaults, used when no `forensiclens.yaml` is found and
    /// as the baseline `ConfigLoader.load` fills gaps in on top of.
    public static let `default` = ForensicLensConfig(
        ela: ELAConfig(
            enabled: true,
            qualityLevel: 75,
            errorThreshold: 28,
            flaggedRegionFraction: 0.015
        ),
        metadata: MetadataConfig(
            enabled: true,
            flagMissingExif: false,
            suspiciousSoftwareKeywords: [
                "photoshop", "gimp", "lightroom", "affinity photo",
                "pixelmator", "snapseed", "paint.net", "picsart"
            ],
            maxTimestampDriftSeconds: 60 * 60 * 24 * 30 // 30 days
        ),
        cloneDetection: CloneDetectionConfig(
            enabled: true,
            blockSize: 16,
            blockStride: 8,
            minimumBlockVariance: 20,
            similarityThreshold: 6,
            minimumBlockDistance: 24
        )
    )
}
