/// How much the plain-language narrative of a report says.
public enum NarrativeVerbosity: String, Sendable, Codable, CaseIterable {
    /// A headline, a one-paragraph summary, the key findings, and any
    /// caveats: what a non-expert needs to know.
    case brief

    /// Everything in `brief`, plus a detector-by-detector walkthrough that
    /// explains what each check looks for and what it concluded, including
    /// the ones that found nothing or didn't apply.
    case full
}
