/// Turns a set of detector findings into one calibrated confidence score.
///
/// `SuspicionScorer` takes the strongest raw score and adds a little for
/// each other one, which treats every detector's 0-100 as equally
/// trustworthy and on the same scale. This is the layer on top of it that
/// doesn't. The rule:
///
/// 1. **Status.** Each finding is classified (`DetectorStatus`). Only
///    flagged findings add evidence; not-applicable, not-assessed, and
///    failed detectors are left out entirely rather than counted as clean.
/// 2. **Normalize.** A flagged detector's raw score is divided by the
///    highest score it can produce (`ScoreNormalizer`), giving a 0...1
///    strength on a scale every detector shares.
/// 3. **Weight.** The strength is multiplied by the detector's reliability
///    (`DetectorProfile.reliability`), lower for detectors documented as
///    prone to false positives: the noise-level check counts 0.4, clone
///    detection 0.95. The result is that detector's evidence `e`.
/// 4. **Combine.** Evidence combines as independent chances of being
///    right, `1 - (1 - e1)(1 - e2)...`, rather than adding up: each
///    detector closes part of the remaining gap to 100, so several weak
///    signals stay well short of what one strong signal reaches, and the
///    total can never exceed 100.
/// 5. **Agreement.** Where flagged regions from detectors in at least two
///    different evidence families overlap (`RegionClustering`), the area
///    gets a boost `b = min(0.6, 0.5 * (k - 1) * m)`, for `k` agreeing
///    families and `m` the mean evidence of the agreeing detectors. Two
///    detectors in the same family (PRNU and the noise-level check, say)
///    read the same trace, so their agreement isn't independent and earns
///    nothing. Only the strongest area's boost is applied, as one more
///    term of step 4: `1 - (1 - c)(1 - b)`.
///
/// The result is scaled to 0-100 and rounded to one decimal. Its verdict
/// uses the suspicion score's bands, except that when no detector could
/// judge the image at all (every one not applicable, not assessed, or
/// failed) it's "inconclusive" rather than "likely authentic".
public struct ConfidenceCalibrator: Sendable {
    /// Boost per agreeing family beyond the first, as a share of the
    /// agreeing detectors' mean evidence.
    public static let agreementFactor = 0.5

    /// The most one area's agreement can add, before combining.
    public static let maximumAgreementBoost = 0.6

    public init() {}

    /// The calibrated confidence for `findings`.
    public func calibrate(_ findings: [AnalyzerFinding]) -> CalibratedConfidence {
        let contributions = findings.map(Self.contribution(for:))
        let agreements = Self.agreements(in: findings, contributions: contributions)
        let boost = agreements.first(where: \.applied)?.boost ?? 0
        let combined = Self.combine(contributions.map(\.evidence) + [boost])
        let score = Self.rounded(combined * 100)
        let anyAssessed = contributions.contains { $0.status.isAssessed }
        let verdict = anyAssessed ? SuspicionScorer.verdict(for: score) : CalibratedConfidence.inconclusiveVerdict
        return CalibratedConfidence(score: score, verdict: verdict, contributions: contributions, agreements: agreements)
    }

    /// Step 5: every area at least two evidence families flagged, with its
    /// boost, strongest first; the first is marked applied.
    static func agreements(in findings: [AnalyzerFinding], contributions: [DetectorContribution]) -> [RegionAgreement] {
        var evidence: [String: Double] = [:]
        for contribution in contributions {
            evidence[contribution.analyzerID] = max(evidence[contribution.analyzerID] ?? 0, contribution.evidence)
        }

        let candidates = RegionClustering.clusters(of: RegionClustering.claims(from: findings))
            .filter { $0.families.count >= 2 }
            .map { cluster -> (cluster: RegionCluster, boost: Double) in
                let ids = cluster.analyzerIDs
                let meanEvidence = ids.reduce(0.0) { $0 + (evidence[$1] ?? 0) } / Double(max(1, ids.count))
                let boost = min(maximumAgreementBoost, agreementFactor * Double(cluster.families.count - 1) * meanEvidence)
                return (cluster, boost)
            }
            .sorted { $0.boost > $1.boost }

        return candidates.enumerated().map { index, candidate in
            RegionAgreement(
                region: candidate.cluster.agreementRegion,
                analyzerIDs: candidate.cluster.analyzerIDs,
                families: candidate.cluster.families.sorted { $0.rawValue < $1.rawValue },
                boost: candidate.boost,
                applied: index == 0 && candidate.boost > 0
            )
        }
    }

    /// Steps 1-3 for one finding.
    static func contribution(for finding: AnalyzerFinding) -> DetectorContribution {
        let profile = DetectorProfile.profile(for: finding.analyzerID)
        let status = DetectorStatus.classify(finding)
        let strength = status == .flagged ? ScoreNormalizer.normalizedStrength(rawScore: finding.score, profile: profile) : 0
        return DetectorContribution(
            analyzerID: finding.analyzerID,
            status: status,
            rawScore: finding.score,
            normalizedStrength: strength,
            reliability: profile.reliability,
            evidence: profile.weightedEvidence(normalizedStrength: strength)
        )
    }

    /// Step 4: `1 - product(1 - e)` over `evidence`, each clamped to 0...1.
    static func combine(_ evidence: [Double]) -> Double {
        1 - evidence.reduce(1.0) { remaining, e in remaining * (1 - min(1, max(0, e))) }
    }

    /// `value` rounded to one decimal place.
    static func rounded(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }
}
