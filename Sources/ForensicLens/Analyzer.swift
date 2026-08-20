import ImageDecoding

/// A single piece of evidence an analyzer surfaced while examining an image.
///
/// Indicators are the itemized building blocks of the human-readable report
/// -- each one is a short, self-contained sentence a non-expert reader can
/// follow ("Software tag reports GIMP 2.10"), plus a numeric `weight` the
/// scorer uses to decide how much this indicator should move the analyzer's
/// overall score. Weight is intentionally on the same 0...100 scale as the
/// finding's own score rather than an arbitrary point system, so an analyzer
/// author can reason about "how suspicious is this one thing" directly.
public struct Indicator: Sendable, Equatable, Codable {
    /// Human-readable description of what was observed.
    public let message: String

    /// How strongly this single observation argues for manipulation, from
    /// 0 (irrelevant) to 100 (essentially conclusive on its own).
    public let weight: Double

    public init(message: String, weight: Double) {
        self.message = message
        self.weight = weight
    }
}

/// The result a single `Analyzer` produces for one image.
///
/// This is deliberately the *only* thing an analyzer hands back to the rest
/// of the package -- `SuspicionScorer` never reaches back into an analyzer's
/// internals, it just combines `AnalyzerFinding` values from whichever
/// analyzers were enabled.
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
/// These are deliberately narrow: an analyzer either can't do its job
/// because the input doesn't have what it needs (`unsupportedInput`), or a
/// step in its own algorithm failed (`analysisFailed`). Decoding failures
/// belong to `ImageDecodingError` and should already have been handled
/// before an `ImageData` reaches an analyzer.
public enum AnalyzerError: Error, Equatable, CustomStringConvertible {
    /// The analyzer needs something `ImageData` doesn't have -- e.g. ELA
    /// needs decoded pixels and got an image with `pixels == nil`.
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
/// Keeping analyzers behind this protocol -- rather than having
/// `SuspicionScorer` call `ELAAnalyzer`, `MetadataAnalyzer`, and
/// `CloneDetectionAnalyzer` by name -- is what makes them independently
/// toggleable from config and independently testable. Adding a fourth
/// analyzer later means writing a type that conforms to `Analyzer` and
/// registering it; nothing else in the package needs to change.
public protocol Analyzer: Sendable {
    /// A short, stable, lowercase identifier used in config files, CLI
    /// flags, and report output (e.g. `"ela"`, `"metadata"`, `"clone"`).
    /// This must never change once released -- it's a public config key.
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
