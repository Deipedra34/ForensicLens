/// Adds the calibrated confidence and, when enabled, the plain-language
/// explanation to a report that `SuspicionScorer` produced.
///
/// This is the only place the two new layers meet the pipeline. It takes a
/// finished report and returns it with `confidence` and `explanation` set,
/// leaving the findings, `overallScore`, and `verdict` exactly as they
/// were. `ForensicLensEngine` runs it on every report, and the web demo's
/// combine step on the report it assembles from per-analyzer runs.
public struct ReportExplainer: Sendable {
    public let settings: ForensicLensConfig.ReportConfig

    public init(settings: ForensicLensConfig.ReportConfig = .default) {
        self.settings = settings
    }

    /// `report` with its calibrated confidence and, unless the narrative is
    /// turned off, its explanation. `imageSize` lets the narrative say
    /// where in the picture a flagged area is.
    public func explain(_ report: ForensicReport, imageSize: ImageSize? = nil) -> ForensicReport {
        let confidence = ConfidenceCalibrator().calibrate(report.findings)
        var explained = report
        explained.confidence = confidence
        explained.explanation = settings.narrative
            ? NarrativeGenerator(verbosity: settings.narrativeVerbosity).explain(findings: report.findings, confidence: confidence, imageSize: imageSize)
            : nil
        return explained
    }
}
