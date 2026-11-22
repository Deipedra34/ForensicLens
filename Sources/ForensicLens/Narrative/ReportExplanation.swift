/// A plain-language explanation of a report, for someone who isn't a
/// forensics expert, plus a technical appendix with the numbers behind it.
///
/// Built by `NarrativeGenerator` from the detectors' findings and the
/// calibrated confidence; rendered by the text report, the HTML report, and
/// the web demo, and included as-is in JSON output. Every field is plain
/// data, so integrations can lay it out their own way.
public struct ReportExplanation: Sendable, Equatable, Codable {
    /// One thing worth knowing, in plain language, with the detectors and
    /// regions it's about.
    public struct KeyFinding: Sendable, Equatable, Codable {
        public let text: String
        public let analyzerIDs: [String]
        public let regions: [Region]

        public init(text: String, analyzerIDs: [String], regions: [Region]) {
            self.text = text
            self.analyzerIDs = analyzerIDs
            self.regions = regions
        }
    }

    /// One detector's part in a full walkthrough.
    public struct DetectorExplanation: Sendable, Equatable, Codable {
        public let analyzerID: String
        /// The plain-language name, e.g. "the copy-paste check".
        public let name: String
        public let status: DetectorStatus
        /// What it looks for and what it concluded, in a sentence or two.
        public let text: String

        public init(analyzerID: String, name: String, status: DetectorStatus, text: String) {
            self.analyzerID = analyzerID
            self.name = name
            self.status = status
            self.text = text
        }
    }

    /// One detector's raw numbers, for the technical appendix.
    public struct AppendixEntry: Sendable, Equatable, Codable {
        public let analyzerID: String
        public let name: String
        public let status: DetectorStatus
        /// The detector's own score, 0-100.
        public let rawScore: Double
        /// The score on the common 0...1 scale.
        public let normalizedStrength: Double
        /// The detector's reliability weight.
        public let reliability: Double
        /// What it added to the calibrated confidence, 0...1.
        public let evidence: Double
        /// The detector's own one-line summary, verbatim.
        public let summary: String

        public init(analyzerID: String, name: String, status: DetectorStatus, rawScore: Double, normalizedStrength: Double, reliability: Double, evidence: Double, summary: String) {
            self.analyzerID = analyzerID
            self.name = name
            self.status = status
            self.rawScore = rawScore
            self.normalizedStrength = normalizedStrength
            self.reliability = reliability
            self.evidence = evidence
            self.summary = summary
        }
    }

    /// The verbosity this explanation was written at.
    public let verbosity: NarrativeVerbosity

    /// One sentence: the bottom line.
    public let headline: String

    /// A short paragraph: how many checks ran, how the score was reached,
    /// and what it is.
    public let summary: String

    /// What was found, most important first: areas several independent
    /// checks agree on, then each check that flagged something.
    public let keyFindings: [KeyFinding]

    /// What to keep in mind when reading the result.
    public let caveats: [String]

    /// Every detector, in run order, with what it looks for and what it
    /// concluded. Only at `full` verbosity; empty at `brief`.
    public let walkthrough: [DetectorExplanation]

    /// The raw per-detector numbers behind the narrative, in run order.
    public let technicalAppendix: [AppendixEntry]

    public init(verbosity: NarrativeVerbosity, headline: String, summary: String, keyFindings: [KeyFinding], caveats: [String], walkthrough: [DetectorExplanation], technicalAppendix: [AppendixEntry]) {
        self.verbosity = verbosity
        self.headline = headline
        self.summary = summary
        self.keyFindings = keyFindings
        self.caveats = caveats
        self.walkthrough = walkthrough
        self.technicalAppendix = technicalAppendix
    }
}
