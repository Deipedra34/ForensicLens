import ImageDecoding

/// The library's main entry point: wires up the built-in analyzers,
/// respects config-driven enable/disable flags, and produces a combined
/// `ForensicReport`.
///
/// This is what both `forensiclens-cli` and any other consumer of the
/// `ForensicLens` library should use rather than constructing individual
/// analyzers by hand -- it's the one place that knows the full set of
/// registered analyzers and how their per-analyzer `enabled` flags in
/// `ForensicLensConfig` map to analyzer identifiers.
public struct ForensicLensEngine: Sendable {
    public let config: ForensicLensConfig
    private let analyzers: [any Analyzer]

    /// Creates an engine with the given config and the full set of built-in
    /// analyzers (ELA, metadata, clone detection). Individual analyzers are
    /// still subject to their `enabled` flag in `config` at run time.
    public init(config: ForensicLensConfig = .default) {
        self.config = config
        self.analyzers = [ELAAnalyzer(), MetadataAnalyzer(), CloneDetectionAnalyzer()]
    }

    /// Runs every enabled analyzer against `image` and combines the results
    /// into a `ForensicReport`.
    ///
    /// - Parameter only: If provided, restricts the run to analyzers whose
    ///   `identifier` is in this set (still subject to `config`'s enabled
    ///   flags). If `nil`, every config-enabled analyzer runs. This is what
    ///   powers the CLI's "run a single analyzer" subcommands.
    public func run(on image: ImageData, only: Set<String>? = nil) -> ForensicReport {
        var findings: [AnalyzerFinding] = []

        for analyzer in analyzers {
            guard isEnabled(analyzer) else { continue }
            if let only, !only.contains(analyzer.identifier) { continue }

            do {
                findings.append(try analyzer.analyze(image, config: config))
            } catch {
                findings.append(AnalyzerFinding(
                    analyzerID: analyzer.identifier,
                    score: 0,
                    summary: "Could not run \(analyzer.displayName): \(error)",
                    indicators: []
                ))
            }
        }

        return SuspicionScorer().score(findings)
    }

    /// All analyzer identifiers this engine knows about, in run order.
    public var availableAnalyzerIDs: [String] {
        analyzers.map(\.identifier)
    }

    private func isEnabled(_ analyzer: any Analyzer) -> Bool {
        switch analyzer.identifier {
        case "ela": return config.ela.enabled
        case "metadata": return config.metadata.enabled
        case "clone": return config.cloneDetection.enabled
        default: return true
        }
    }
}
