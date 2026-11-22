/// Writes the plain-language explanation of a report.
///
/// Everything is assembled from fixed templates -- `DetectorWording` for
/// what each check is and means, `RegionDescriber` for where things are --
/// filled in with the numbers and regions from the findings and the
/// calibrated confidence. The same input always gives the same text, and
/// nothing here touches the network or calls out to any service.
///
/// `findings` and `confidence` must describe the same run, with the
/// confidence computed from those findings (`ConfidenceCalibrator`), so its
/// contributions line up with the findings one-to-one.
public struct NarrativeGenerator: Sendable {
    public let verbosity: NarrativeVerbosity

    /// At `brief` verbosity, how many flagging checks get a key finding of
    /// their own (strongest evidence first); the rest are summed up in one
    /// line. `full` lists every one.
    static let briefDetectorLimit = 3

    /// How many regions a key finding spells out before saying "and N more".
    static let briefRegionLimit = 3
    static let fullRegionLimit = 8

    public init(verbosity: NarrativeVerbosity = .brief) {
        self.verbosity = verbosity
    }

    /// The explanation of `findings`, given their calibrated `confidence`.
    /// `imageSize`, when known, lets regions be described by where they are
    /// in the picture.
    public func explain(findings: [AnalyzerFinding], confidence: CalibratedConfidence, imageSize: ImageSize? = nil) -> ReportExplanation {
        ReportExplanation(
            verbosity: verbosity,
            headline: Self.headline(for: confidence),
            summary: Self.summary(for: confidence),
            keyFindings: keyFindings(findings: findings, confidence: confidence, imageSize: imageSize),
            caveats: [],
            walkthrough: [],
            technicalAppendix: []
        )
    }

    // MARK: - Headline and summary

    /// The bottom line, by verdict band.
    static func headline(for confidence: CalibratedConfidence) -> String {
        if confidence.isInconclusive {
            return "Inconclusive: none of the checks could examine this image."
        }
        let flaggedCount = confidence.contributions.filter { $0.status == .flagged }.count
        switch confidence.score {
        case ..<20:
            return flaggedCount == 0
                ? "No signs of manipulation were found."
                : "Only weak, isolated signs of manipulation were found."
        case ..<45:
            return "A few minor anomalies were found, but nothing conclusive."
        case ..<70:
            return "Suspicious: there is some evidence this image was edited."
        default:
            return "Likely manipulated: there is strong evidence this image was edited."
        }
    }

    /// How many checks ran and could judge the image, how the score was
    /// reached, and the score.
    static func summary(for confidence: CalibratedConfidence) -> String {
        let total = confidence.totalDetectors
        let ran = "ForensicLens ran \(total) \(plural(total, "check", "checks"))"
        guard !confidence.isInconclusive else {
            return "\(ran), but none of them could examine this image, so there is no evidence either way. That is not the same as the image being authentic."
        }

        let assessed = confidence.assessedDetectors
        let flaggedCount = confidence.contributions.filter { $0.status == .flagged }.count
        let couldExamine = assessed == total
            ? "all of them could examine this image"
            : "\(assessed) of them could examine this image"
        let found = flaggedCount == 0
            ? "none found anything unusual"
            : "\(flaggedCount) found something"
        let score = "\(formatted(confidence.score))/100 (\(confidence.verdict))"

        guard flaggedCount > 0 else {
            return "\(ran); \(couldExamine), and \(found). The calibrated confidence that it was manipulated is \(score)."
        }
        let agreement = confidence.agreements.contains(where: \.applied)
            ? " and extra weight where independent checks point at the same area"
            : ""
        return "\(ran); \(couldExamine), and \(found). Combining their results, with less weight on checks that often flag untouched photos\(agreement), gives a calibrated confidence of \(score) that the image was manipulated."
    }

    // MARK: - Key findings

    /// Areas independent checks agree on first, then each check that
    /// flagged something, strongest evidence first.
    func keyFindings(findings: [AnalyzerFinding], confidence: CalibratedConfidence, imageSize: ImageSize?) -> [ReportExplanation.KeyFinding] {
        var result: [ReportExplanation.KeyFinding] = []

        for agreement in confidence.agreements {
            let names = agreement.analyzerIDs.map { DetectorWording.wording(for: $0).name }
            let place = Self.capitalized(RegionDescriber.describe(agreement.region, in: imageSize))
            let weight = agreement.applied
                ? "These checks look for different kinds of traces, so their agreement on the same area is the strongest evidence in this report."
                : "Independent checks agree here too."
            result.append(ReportExplanation.KeyFinding(
                text: "\(place) was flagged by \(RegionDescriber.joined(names)). \(weight)",
                analyzerIDs: agreement.analyzerIDs,
                regions: [agreement.region]
            ))
        }

        let flagged = zip(findings, confidence.contributions)
            .filter { $0.1.status == .flagged }
            .sorted { $0.1.evidence > $1.1.evidence }
        let listed = verbosity == .brief ? Array(flagged.prefix(Self.briefDetectorLimit)) : flagged
        let regionLimit = verbosity == .brief ? Self.briefRegionLimit : Self.fullRegionLimit

        for (finding, contribution) in listed {
            let wording = DetectorWording.wording(for: finding.analyzerID)
            let regions = DetectorProfile.profile(for: finding.analyzerID).localizes ? Self.regions(of: finding) : []
            var text = "\(Self.capitalized(wording.name)) found a \(Self.strengthWord(contribution.normalizedStrength)) signal. \(wording.flagMeaning)"
            if !regions.isEmpty {
                text += " Where: \(RegionDescriber.list(regions, in: imageSize, limit: regionLimit))."
            } else if let detail = finding.indicators.max(by: { $0.weight < $1.weight })?.message {
                text += " Detail: \(detail)"
            }
            result.append(ReportExplanation.KeyFinding(text: text, analyzerIDs: [finding.analyzerID], regions: regions))
        }

        let unlisted = flagged.dropFirst(listed.count)
        if !unlisted.isEmpty {
            let names = unlisted.map { DetectorWording.wording(for: $0.0.analyzerID).name }
            result.append(ReportExplanation.KeyFinding(
                text: "\(Self.capitalized(RegionDescriber.joined(names))) also found weaker signals; see the technical details.",
                analyzerIDs: unlisted.map { $0.0.analyzerID },
                regions: []
            ))
        }
        return result
    }

    /// The distinct regions on `finding`'s indicators, in order.
    static func regions(of finding: AnalyzerFinding) -> [Region] {
        var seen = Set<Region>()
        return finding.indicators.flatMap(\.regions).filter { seen.insert($0).inserted }
    }

    /// "strong", "moderate", or "weak", for a normalized strength.
    static func strengthWord(_ normalizedStrength: Double) -> String {
        switch normalizedStrength {
        case 0.75...: return "strong"
        case 0.4...: return "moderate"
        default: return "weak"
        }
    }

    // MARK: - Helpers

    static func plural(_ count: Int, _ singular: String, _ plural: String) -> String {
        count == 1 ? singular : plural
    }

    /// `85.5` as "85.5", `40.0` as "40".
    static func formatted(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        if rounded == rounded.rounded() {
            return String(Int(rounded))
        }
        return String(rounded)
    }

    /// `text` with its first letter capitalized.
    static func capitalized(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }
}
