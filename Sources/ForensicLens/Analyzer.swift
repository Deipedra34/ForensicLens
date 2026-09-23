import ImageDecoding

/// A rectangular area of the analyzed image, in the original image's pixel
/// coordinates (origin at the top-left corner, `x` to the right, `y` down).
///
/// This is how a spatial analyzer says *where* an indicator was observed,
/// so a report can point at the exact spot instead of leaving a reader to
/// cross-reference coordinates in a sentence by hand -- the HTML report
/// draws one overlay box per region, for instance.
public struct Region: Sendable, Hashable, Codable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// This region shifted by `(dx, dy)` -- e.g. from a tile's local
    /// coordinates back into full-image coordinates.
    public func offsetBy(dx: Int, dy: Int) -> Region {
        Region(x: x + dx, y: y + dy, width: width, height: height)
    }

    /// The overlap between this region and `other`, or `nil` if they don't
    /// overlap at all.
    public func intersection(_ other: Region) -> Region? {
        let x0 = max(x, other.x)
        let y0 = max(y, other.y)
        let x1 = min(x + width, other.x + other.width)
        let y1 = min(y + height, other.y + other.height)
        guard x1 > x0, y1 > y0 else { return nil }
        return Region(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}

/// A single piece of evidence an analyzer surfaced while examining an image.
///
/// Indicators are the itemized building blocks of the human-readable report.
/// Each one is a short, self-contained sentence a non-expert reader can
/// follow ("Software tag reports GIMP 2.10"), plus a numeric `weight` the
/// scorer uses to decide how much it should move the analyzer's overall
/// score. Weight lives on the same 0...100 scale as the finding's own score
/// instead of some made-up point system, mostly so whoever's writing an
/// analyzer can just ask "how suspicious is this one thing" and answer it
/// directly.
public struct Indicator: Sendable, Equatable, Codable {
    /// Human-readable description of what was observed.
    public let message: String

    /// How strongly this single observation argues for manipulation, from
    /// 0 (irrelevant) to 100 (essentially conclusive on its own).
    public let weight: Double

    /// Where in the image this observation was made, if it's localized.
    /// Empty for non-spatial evidence (an EXIF tag, say). A clone-detection
    /// match carries two regions -- the source block and its copy -- and a
    /// summary indicator can carry every region it summarizes.
    public let regions: [Region]

    public init(message: String, weight: Double, regions: [Region] = []) {
        self.message = message
        self.weight = weight
        self.regions = regions
    }

    private enum CodingKeys: String, CodingKey {
        case message, weight, regions
    }

    // Hand-written so `regions` stays optional on the wire: omitted from
    // JSON when empty (a non-spatial indicator's JSON reads exactly as it
    // did before regions existed), and tolerated as missing when decoding
    // JSON written before this field was added.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        message = try container.decode(String.self, forKey: .message)
        weight = try container.decode(Double.self, forKey: .weight)
        regions = try container.decodeIfPresent([Region].self, forKey: .regions) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(message, forKey: .message)
        try container.encode(weight, forKey: .weight)
        if !regions.isEmpty {
            try container.encode(regions, forKey: .regions)
        }
    }
}

/// The result a single `Analyzer` produces for one image.
///
/// This is the only thing an analyzer hands back to the rest of the
/// package. `SuspicionScorer` never reaches back into an analyzer's
/// internals; it just combines whatever `AnalyzerFinding` values came out
/// of the analyzers that were enabled.
public struct AnalyzerFinding: Sendable, Equatable, Codable {
    /// Matches the producing analyzer's `Analyzer.identifier`.
    public let analyzerID: String

    /// This analyzer's own suspicion score for the image, 0 (clean) to
    /// 100 (strong evidence of manipulation).
    public let score: Double

    /// One-line summary suitable for a report's headline per analyzer.
    public let summary: String

    /// The individual observations that were combined into `score`.
    public let indicators: [Indicator]

    public init(analyzerID: String, score: Double, summary: String, indicators: [Indicator]) {
        self.analyzerID = analyzerID
        self.score = score.clampedToScore
        self.summary = summary
        self.indicators = indicators
    }

    /// A finding for an analyzer that ran but found nothing worth reporting.
    public static func clean(analyzerID: String, summary: String) -> AnalyzerFinding {
        AnalyzerFinding(analyzerID: analyzerID, score: 0, summary: summary, indicators: [])
    }
}

/// Errors an analyzer can throw while examining an image.
///
/// Kept narrow on purpose: an analyzer either can't do its job because the
/// input doesn't have what it needs (`unsupportedInput`), or a step in its
/// own algorithm went wrong (`analysisFailed`). Decoding failures belong to
/// `ImageDecodingError` and should already be handled before an `ImageData`
/// ever reaches an analyzer.
public enum AnalyzerError: Error, Equatable, CustomStringConvertible {
    /// The analyzer needs something `ImageData` doesn't have. ELA, for
    /// example, needs decoded pixels and got an image with `pixels == nil`.
    case unsupportedInput(String)

    /// The analyzer's own algorithm failed partway through.
    case analysisFailed(String)

    public var description: String {
        switch self {
        case .unsupportedInput(let detail):
            return "Analyzer cannot run on this input: \(detail)"
        case .analysisFailed(let detail):
            return "Analysis failed: \(detail)"
        }
    }
}

/// The shared contract every detection module conforms to.
///
/// Instead of having `SuspicionScorer` call `ELAAnalyzer`, `MetadataAnalyzer`,
/// and `CloneDetectionAnalyzer` by name, everything talks to this protocol.
/// That's what lets each one be toggled from config and tested on its own.
/// Adding a fourth analyzer later just means writing a type that conforms
/// to `Analyzer` and registering it — nothing else in the package has to
/// change.
public protocol Analyzer: Sendable {
    /// A short, stable, lowercase identifier used in config files, CLI
    /// flags, and report output (e.g. `"ela"`, `"metadata"`, `"clone"`).
    /// Don't change this once it ships; it's effectively a public config key.
    var identifier: String { get }

    /// A longer, human-readable name for report headings (e.g.
    /// "Error Level Analysis").
    var displayName: String { get }

    /// Examines `image` and returns this analyzer's findings.
    ///
    /// - Throws: `AnalyzerError.unsupportedInput` if `image` doesn't contain
    ///   what this analyzer needs (for example, ELA requires `image.pixels`
    ///   to be non-nil). Callers should treat this as "this analyzer could
    ///   not evaluate this particular image" rather than a hard failure of
    ///   the overall report.
    func analyze(_ image: ImageData, config: ForensicLensConfig) throws -> AnalyzerFinding
}

extension Double {
    /// Clamps a raw score into the 0...100 range every `AnalyzerFinding`
    /// and the combined report score are expressed in.
    var clampedToScore: Double {
        min(100, max(0, self))
    }
}
