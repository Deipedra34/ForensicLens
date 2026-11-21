/// One detector's part in a calibrated confidence: its raw score, and each
/// step that turned it into evidence.
public struct DetectorContribution: Sendable, Equatable, Codable {
    public let analyzerID: String

    /// Whether the detector could judge the image; see `DetectorStatus`.
    public let status: DetectorStatus

    /// The detector's own score, 0-100, exactly as it reported it.
    public let rawScore: Double

    /// `rawScore` on the common 0...1 scale (see `ScoreNormalizer`). 0
    /// unless the detector flagged something.
    public let normalizedStrength: Double

    /// The detector's reliability weight (see `DetectorProfile`).
    public let reliability: Double

    /// `normalizedStrength * reliability`: what this detector adds to the
    /// calibrated confidence, 0...1.
    public let evidence: Double

    public init(analyzerID: String, status: DetectorStatus, rawScore: Double, normalizedStrength: Double, reliability: Double, evidence: Double) {
        self.analyzerID = analyzerID
        self.status = status
        self.rawScore = rawScore
        self.normalizedStrength = normalizedStrength
        self.reliability = reliability
        self.evidence = evidence
    }
}

/// The calibrated result of combining every detector's finding: how
/// confident ForensicLens is, 0-100, that the image was manipulated, and
/// exactly how each detector contributed. See `ConfidenceCalibrator` for
/// the rule.
public struct CalibratedConfidence: Sendable, Equatable, Codable {
    /// Calibrated confidence that the image was manipulated, 0-100, rounded
    /// to one decimal.
    public let score: Double

    /// A short verdict for `score`, on the same bands as the suspicion
    /// score's.
    public let verdict: String

    /// Every detector's contribution, in the order the findings came in.
    public let contributions: [DetectorContribution]

    public init(score: Double, verdict: String, contributions: [DetectorContribution]) {
        self.score = score
        self.verdict = verdict
        self.contributions = contributions
    }
}
