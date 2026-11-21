/// Puts every detector's raw score on one 0...1 evidence scale.
///
/// Each analyzer scores 0-100, but not on the same scale: some can't reach
/// 100 at all (the noise-level check stops at 80, the AI-generated image
/// check at 75, the thumbnail check at 90), so a raw 75 means "as strong as
/// this check ever gets" for one detector and "fairly strong" for another.
/// Dividing by each detector's ceiling (`DetectorProfile.scoreCeiling`)
/// makes 1.0 mean "this detector's strongest possible finding" for all of
/// them, before any weighting.
public enum ScoreNormalizer {
    /// `rawScore` divided by the detector's ceiling, clamped to 0...1.
    public static func normalizedStrength(rawScore: Double, profile: DetectorProfile) -> Double {
        guard profile.scoreCeiling > 0, rawScore.isFinite else { return 0 }
        return min(1, max(0, rawScore / profile.scoreCeiling))
    }

    /// The normalized strength of `finding`, using its analyzer's profile.
    public static func normalizedStrength(of finding: AnalyzerFinding) -> Double {
        normalizedStrength(rawScore: finding.score, profile: DetectorProfile.profile(for: finding.analyzerID))
    }
}
