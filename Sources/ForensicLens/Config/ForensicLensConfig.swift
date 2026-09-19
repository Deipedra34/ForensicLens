/// Typed, per-analyzer configuration loaded from `forensiclens.yaml` at
/// startup.
///
/// Every analyzer gets its own nested config struct with an `enabled` flag,
/// so the CLI (or a library caller) can turn analyzers on and off and tune
/// their thresholds without touching code. `ForensicLensConfig` itself
/// doesn't really do anything beyond holding these values; it's the
/// analyzers that give them meaning.
public struct ForensicLensConfig: Codable, Equatable, Sendable {
    /// Settings for `ELAAnalyzer`.
    public struct ELAConfig: Codable, Equatable, Sendable {
        /// Whether ELA runs as part of a combined report.
        public var enabled: Bool

        /// The JPEG-style recompression qualities used to generate the
        /// comparison images, each from 1 (heavy quantization) to 100
        /// (almost lossless). ELA recompresses at every level in this list
        /// and combines the results, rather than trusting a single
        /// arbitrarily-chosen quality; see `ELAAnalyzer`'s doc comment for
        /// why that combination is worth the extra recompression passes.
        /// An empty (or otherwise invalid) list falls back to
        /// `ELAAnalyzer.defaultQualityLevels` rather than crashing.
        public var elaQualityLevels: [Int]

        /// A per-pixel luma error above this (0...255) is considered part
        /// of a "hot" region rather than ordinary recompression noise. This
        /// is also the per-level bar a pixel's error must clear to count
        /// toward that pixel's cross-level agreement -- see
        /// `ELAAnalyzer.combine`'s doc comment.
        public var errorThreshold: Double

        /// The fraction of the image (0...1) that must fall in hot regions
        /// before ELA treats the image as suspicious rather than just
        /// noting some recompression noise, which every JPEG has.
        public var flaggedRegionFraction: Double

        public init(enabled: Bool, elaQualityLevels: [Int], errorThreshold: Double, flaggedRegionFraction: Double) {
            self.enabled = enabled
            self.elaQualityLevels = elaQualityLevels
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

        /// The largest gap, in seconds, allowed between the GPS timestamp
        /// (`GPSDateStamp`/`GPSTimeStamp`, always UTC) and `DateTimeOriginal`
        /// before it's flagged. Kept small since this is meant to catch
        /// clock desync, not timezone offsets -- see
        /// `MetadataAnomaly.gpsTimestampDrift`'s doc comment for that
        /// assumption's limits. Default is 5 minutes.
        public var maxGPSTimestampDriftSeconds: Int

        /// The largest gap, in seconds, allowed between `DateTimeDigitized`
        /// and `DateTimeOriginal` before it's flagged. For a straight-from-
        /// camera JPEG these are normally seconds apart; a bigger gap
        /// suggests the file was digitized separately from capture, as
        /// happens when an editor re-saves it. Default is 5 minutes.
        public var maxDigitizedDriftSeconds: Int

        public init(enabled: Bool, flagMissingExif: Bool, suspiciousSoftwareKeywords: [String], maxTimestampDriftSeconds: Int, maxGPSTimestampDriftSeconds: Int, maxDigitizedDriftSeconds: Int) {
            self.enabled = enabled
            self.flagMissingExif = flagMissingExif
            self.suspiciousSoftwareKeywords = suspiciousSoftwareKeywords
            self.maxTimestampDriftSeconds = maxTimestampDriftSeconds
            self.maxGPSTimestampDriftSeconds = maxGPSTimestampDriftSeconds
            self.maxDigitizedDriftSeconds = maxDigitizedDriftSeconds
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

    /// Settings for `DoubleCompressionAnalyzer`.
    public struct DoubleCompressionConfig: Codable, Equatable, Sendable {
        /// Whether double-compression detection runs as part of a combined
        /// report.
        public var enabled: Bool

        /// Row (0...7) of the 8x8 DCT coefficient this analyzer builds its
        /// histogram from. `(1, 1)` is a low-frequency AC term: high enough
        /// that it isn't dominated by the DC (average brightness) term, but
        /// low enough that it still carries plenty of energy in ordinary
        /// photo content for the histogram to be worth analyzing. Clamped
        /// to 0...7 if a config file supplies something out of range.
        public var acCoefficientRow: Int

        /// Column (0...7) of the coefficient position; see
        /// `acCoefficientRow`. Together `(acCoefficientRow, acCoefficientColumn)`
        /// name one of the 64 positions in an 8x8 DCT block.
        public var acCoefficientColumn: Int

        /// How much of the coefficient histogram's spectral energy has to
        /// concentrate in a single frequency, on a 0...1 scale, before that
        /// histogram counts as showing a periodic double-compression comb
        /// rather than an ordinary single-compression histogram's smooth
        /// shape. Higher is stricter (fewer false positives, but subtler
        /// double-compression evidence can slip under it).
        public var periodicityThreshold: Double

        public init(enabled: Bool, acCoefficientRow: Int, acCoefficientColumn: Int, periodicityThreshold: Double) {
            self.enabled = enabled
            self.acCoefficientRow = acCoefficientRow
            self.acCoefficientColumn = acCoefficientColumn
            self.periodicityThreshold = periodicityThreshold
        }
    }

    /// Settings for the tiling layer (see `Sources/ForensicLens/Tiling`)
    /// that splits a large image into overlapping tiles before handing it
    /// to the analyzers above, rather than processing the whole decoded
    /// pixel buffer as one block.
    public struct TilingConfig: Codable, Equatable, Sendable {
        /// Master switch for tiling. When `false`, every image is always
        /// processed as a single block regardless of `tilingThreshold` --
        /// equivalent to always passing `--no-tiling` on the CLI.
        public var enabled: Bool

        /// An image is only tiled once its larger dimension (`max(width,
        /// height)`) exceeds this many pixels. Images at or below the
        /// threshold are processed exactly as they were before tiling
        /// existed -- as a single block -- so this feature changes nothing
        /// for the vast majority of ordinary-sized inputs.
        public var tilingThreshold: Int

        /// Side length, in pixels, of each tile's exclusive "core" region
        /// before overlap is added. Rounded to the nearest multiple of 8
        /// (minimum 8) when a `TilePlan` is built, for the same 8x8 JPEG
        /// block-alignment reason documented on `tileOverlap`.
        public var tileSize: Int

        /// How many pixels of extra surrounding context (a "halo") are
        /// read on every side of a tile's core region before an analyzer
        /// runs against it.
        ///
        /// This must be a multiple of 8 pixels. `ELAAnalyzer` and
        /// `DoubleCompressionAnalyzer` both work in JPEG's native 8x8 DCT
        /// block grid, and that grid is anchored to whatever buffer they're
        /// given -- always starting at local `(0, 0)`. A tile's core origin
        /// is always placed on a multiple of `tileSize` (itself rounded to
        /// a multiple of 8), so as long as the halo subtracted from it is
        /// *also* a multiple of 8, the tile's extraction origin
        /// (`core origin - halo`) stays on a multiple of 8 too -- keeping
        /// the tile-local 8x8 grid perfectly in phase with the grid a
        /// single-block pass over the whole image would have used. Get
        /// this wrong (an overlap not divisible by 8) and a tile's DCT
        /// blocks land out of phase with their neighbors, producing a
        /// visible seam of spurious recompression error right at the tile
        /// boundary that has nothing to do with the image content.
        public var tileOverlap: Int

        public init(enabled: Bool, tilingThreshold: Int, tileSize: Int, tileOverlap: Int) {
            self.enabled = enabled
            self.tilingThreshold = tilingThreshold
            self.tileSize = tileSize
            self.tileOverlap = tileOverlap
        }

        /// Standalone defaults for `TilingConfig` on its own (rather than
        /// reaching through `ForensicLensConfig.default`, which is defined
        /// in terms of this type and would recurse). `tileOverlap` (64) is
        /// a multiple of 8 per this type's own doc comment.
        public static let `default` = TilingConfig(
            enabled: true,
            tilingThreshold: 4096,
            tileSize: 1024,
            tileOverlap: 64
        )
    }

    public var ela: ELAConfig
    public var metadata: MetadataConfig
    public var cloneDetection: CloneDetectionConfig
    public var doubleCompression: DoubleCompressionConfig
    public var tiling: TilingConfig

    public init(ela: ELAConfig, metadata: MetadataConfig, cloneDetection: CloneDetectionConfig, doubleCompression: DoubleCompressionConfig, tiling: TilingConfig = TilingConfig.default) {
        self.ela = ela
        self.metadata = metadata
        self.cloneDetection = cloneDetection
        self.doubleCompression = doubleCompression
        self.tiling = tiling
    }

    /// Reasonable defaults, used when no `forensiclens.yaml` is found and
    /// as the baseline `ConfigLoader.load` fills gaps in on top of.
    public static let `default` = ForensicLensConfig(
        ela: ELAConfig(
            enabled: true,
            elaQualityLevels: [70, 80, 90],
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
            maxTimestampDriftSeconds: 60 * 60 * 24 * 30, // 30 days
            maxGPSTimestampDriftSeconds: 60 * 5, // 5 minutes
            maxDigitizedDriftSeconds: 60 * 5 // 5 minutes
        ),
        cloneDetection: CloneDetectionConfig(
            enabled: true,
            blockSize: 16,
            blockStride: 8,
            minimumBlockVariance: 20,
            similarityThreshold: 6,
            minimumBlockDistance: 24
        ),
        doubleCompression: DoubleCompressionConfig(
            enabled: true,
            acCoefficientRow: 1,
            acCoefficientColumn: 1,
            periodicityThreshold: 0.24
        ),
        tiling: TilingConfig.default
    )
}
