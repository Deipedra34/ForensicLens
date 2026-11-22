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
            keyFindings: [],
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
