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

/// An area that detectors from more than one independent evidence family
/// flagged, and how much their agreement raised the calibrated confidence.
public struct RegionAgreement: Sendable, Equatable, Codable {
    /// The smallest rectangle containing every agreeing detector's region.
    public let region: Region

    /// The detectors that flagged this area, sorted.
    public let analyzerIDs: [String]

    /// Their distinct evidence families, sorted; at least two.
    public let families: [EvidenceFamily]

    /// The extra confidence this agreement is worth, 0...1 (see
    /// `ConfidenceCalibrator`).
    public let boost: Double

    /// Whether this is the agreement that was applied. Only the strongest
    /// one is, so the same detectors agreeing on several areas don't stack.
    public let applied: Bool

    public init(region: Region, analyzerIDs: [String], families: [EvidenceFamily], boost: Double, applied: Bool) {
        self.region = region
        self.analyzerIDs = analyzerIDs
        self.families = families
        self.boost = boost
        self.applied = applied
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
    /// score's, or `CalibratedConfidence.inconclusiveVerdict` when no
    /// detector could judge the image at all.
    public let verdict: String

    /// How many detectors could judge the image (flagged or clean).
    public let assessedDetectors: Int

    /// How many detectors ran, including those that were not applicable,
    /// not assessed, or failed.
    public let totalDetectors: Int

    /// Every detector's contribution, in the order the findings came in.
    public let contributions: [DetectorContribution]

    /// Areas independent detectors agreed on, strongest first. Empty when no
    /// two families flagged overlapping regions.
    public let agreements: [RegionAgreement]

    public init(score: Double, verdict: String, contributions: [DetectorContribution], agreements: [RegionAgreement] = []) {
        self.score = score
        self.verdict = verdict
        self.contributions = contributions
        self.agreements = agreements
        self.assessedDetectors = contributions.filter { $0.status.isAssessed }.count
        self.totalDetectors = contributions.count
    }

    /// The verdict when every detector was not applicable, not assessed, or
    /// failed: a score of 0 then means "no evidence either way", not
    /// "likely authentic".
    public static let inconclusiveVerdict = "inconclusive"

    /// Whether no detector could judge the image.
    public var isInconclusive: Bool {
        assessedDetectors == 0
    }
}
