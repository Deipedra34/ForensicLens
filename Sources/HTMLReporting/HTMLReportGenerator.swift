import ForensicLens
import ImageDecoding

/// Renders a `ForensicReport` as a single, self-contained HTML page: the
/// analyzed image embedded as a `data:` URI, each spatial analyzer's
/// flagged regions drawn over it as a toggleable, color-coded layer, and
/// the same per-analyzer breakdown the text/JSON report carries.
///
/// This only *consumes* analyzer output -- a finished `ForensicReport` and
/// the `ImageData` it was produced from -- and never runs or reaches into
/// an analyzer itself. Everything it draws comes from `Indicator.regions`.
///
/// The page is assembled from small, named pieces (`header`,
/// `layerToggles`, `imageStage`, `legend`, `breakdown`, `toggleScript`)
/// rather than one long string, so each part of the markup can be read
/// and changed on its own.
public struct HTMLReportGenerator: Sendable {
    public init() {}

    /// Renders the full report page.
    ///
    /// - Parameters:
    ///   - report: The combined result of the analysis run.
    ///   - image: The image `report` was produced from, embedded in the
    ///     page and used as the overlay coordinate space.
    ///   - sourcePath: The analyzed file's path, shown in the page header.
    public func render(report: ForensicReport, image: ImageData, sourcePath: String) -> String {
        let embedded = EmbeddedImage.from(image)
        let layers = Self.overlayLayers(for: report)

        let body = [
            header(report: report, sourcePath: sourcePath),
            layerToggles(layers),
            imageStage(embedded, layers: layers),
            legend(layers),
            breakdown(report),
        ].joined(separator: "\n")

        return HTMLTemplate.document(
            title: "ForensicLens Report - \(Self.fileName(of: sourcePath))",
            extraStyle: Self.reportStyle,
            body: body,
            script: layers.isEmpty ? "" : Self.toggleScript
        )
    }

    // MARK: - Overlay layers

    /// One analyzer's overlay: its color, its display name, and every
    /// distinct region its indicators reported.
    struct OverlayLayer: Equatable {
        let analyzerID: String
        let name: String
        let color: String
        let regions: [Region]
    }

    /// Fixed colors for the built-in spatial analyzers, chosen to stay
    /// distinguishable from each other and readable over most photos. An
    /// analyzer not listed here (a future one that starts reporting
    /// regions) still gets a layer, in `fallbackColor`.
    static let layerColors: [String: String] = [
        "ela": "#f76707",
        "clone": "#1c7ed6",
        "doublecompression": "#ae3ec9",
    ]
    static let fallbackColor = "#868e96"

    /// Human-readable analyzer names, read from the analyzers themselves
    /// so they can't drift from what the rest of the package calls them.
    static let displayNames: [String: String] = {
        let analyzers: [any Analyzer] = [ELAAnalyzer(), MetadataAnalyzer(), CloneDetectionAnalyzer(), DoubleCompressionAnalyzer()]
        return Dictionary(uniqueKeysWithValues: analyzers.map { ($0.identifier, $0.displayName) })
    }()

    static func displayName(for analyzerID: String) -> String {
        displayNames[analyzerID] ?? analyzerID
    }

    /// Builds one layer per analyzer that either is a known spatial
    /// analyzer or actually reported regions, in the order the analyzers
    /// ran. Regions are de-duplicated per layer: a summary indicator and a
    /// per-region indicator often point at the same box, and it should be
    /// drawn once.
    static func overlayLayers(for report: ForensicReport) -> [OverlayLayer] {
        report.findings.compactMap { finding -> OverlayLayer? in
            var seen = Set<Region>()
            let regions = finding.indicators
                .flatMap(\.regions)
                .filter { seen.insert($0).inserted }

            let color = layerColors[finding.analyzerID]
            guard color != nil || !regions.isEmpty else { return nil }

            return OverlayLayer(
                analyzerID: finding.analyzerID,
                name: displayName(for: finding.analyzerID),
                color: color ?? fallbackColor,
                regions: regions
            )
        }
    }

    // MARK: - Page pieces

    func header(report: ForensicReport, sourcePath: String) -> String {
        let score = HTMLTemplate.scoreText(report.overallScore)
        let severity = HTMLTemplate.severityClass(report.overallScore)
        let anomalyBanner = Self.hasAnomalies(report)
            ? ""
            : "\n<p class=\"no-anomalies\">No anomalies detected.</p>"

        return """
        <header class="card report-header">
        <div>
        <h1>ForensicLens Report</h1>
        <p class="path">\(HTMLTemplate.escape(sourcePath))</p>
        </div>
        <div class="score-block">
        <div class="score \(severity)" id="overall-score" data-score="\(score)"><span class="score-value">\(score)</span><span class="score-max">/100</span></div>
        <div class="verdict \(severity)">\(HTMLTemplate.escape(report.verdict))</div>
        </div>
        </header>\(anomalyBanner)
        """
    }

    func layerToggles(_ layers: [OverlayLayer]) -> String {
        guard !layers.isEmpty else { return "" }
        let toggles = layers.map { layer -> String in
            let id = HTMLTemplate.escape(layer.analyzerID)
            return """
            <label class="toggle"><input type="checkbox" checked data-layer="\(id)"> <span class="swatch" style="background:\(layer.color)"></span>\(HTMLTemplate.escape(layer.name))</label>
            """
        }
        return """
        <div class="toggles" role="group" aria-label="Overlay layers">
        \(toggles.joined(separator: "\n"))
        </div>
        """
    }

    func imageStage(_ image: EmbeddedImage?, layers: [OverlayLayer]) -> String {
        guard let image else {
            return "<div class=\"card image-missing\">Image preview unavailable: this file's format can't be displayed in a browser and has no decoded pixels to convert.</div>"
        }

        var sizeAttributes = ""
        var overlay = ""
        if let width = image.width, let height = image.height {
            sizeAttributes = " width=\"\(width)\" height=\"\(height)\""
            overlay = "\n" + overlaySVG(layers, width: width, height: height)
        }

        return """
        <figure class="stage">
        <img id="analyzed-image" src="\(image.dataURI)" alt="Analyzed image"\(sizeAttributes)>\(overlay)
        </figure>
        """
    }

    /// An SVG laid exactly over the image, whose `viewBox` is the image's
    /// own pixel grid -- so every `<rect>` uses the region's original pixel
    /// coordinates verbatim and still lines up at whatever size the image
    /// ends up displayed.
    func overlaySVG(_ layers: [OverlayLayer], width: Int, height: Int) -> String {
        let groups = layers.map { layer -> String in
            let id = HTMLTemplate.escape(layer.analyzerID)
            let name = HTMLTemplate.escape(layer.name)
            let rects = layer.regions.map { region in
                "<rect class=\"overlay\" data-analyzer=\"\(id)\" x=\"\(region.x)\" y=\"\(region.y)\" width=\"\(region.width)\" height=\"\(region.height)\"><title>\(name): \(Self.describe(region))</title></rect>"
            }
            return """
            <g class="layer" data-layer="\(id)" fill="\(layer.color)" stroke="\(layer.color)">
            \(rects.joined(separator: "\n"))
            </g>
            """
        }
        return """
        <svg class="overlays" viewBox="0 0 \(width) \(height)" preserveAspectRatio="none" xmlns="http://www.w3.org/2000/svg">
        \(groups.joined(separator: "\n"))
        </svg>
        """
    }

    func legend(_ layers: [OverlayLayer]) -> String {
        guard !layers.isEmpty else { return "" }
        let entries = layers.map { layer -> String in
            let count = layer.regions.count
            return "<li class=\"legend-entry\" data-analyzer=\"\(HTMLTemplate.escape(layer.analyzerID))\"><span class=\"swatch\" style=\"background:\(layer.color)\"></span>\(HTMLTemplate.escape(layer.name)) <span class=\"muted\">(\(count) region\(count == 1 ? "" : "s"))</span></li>"
        }
        return """
        <ul class="legend">
        \(entries.joined(separator: "\n"))
        </ul>
        """
    }

    /// The per-analyzer findings, carrying the same information as
    /// `ForensicReport.textReport`, plus each indicator's region
    /// coordinates.
    func breakdown(_ report: ForensicReport) -> String {
        guard !report.findings.isEmpty else {
            return """
            <h2>Findings</h2>
            <p class="card no-anomalies">No anomalies detected. No analyzers produced findings for this image.</p>
            """
        }

        let sections = report.findings.map { finding -> String in
            let severity = HTMLTemplate.severityClass(finding.score)
            let indicators = finding.indicators.map { indicator -> String in
                "<li>\(HTMLTemplate.escape(indicator.message))\(Self.regionList(indicator.regions))</li>"
            }
            let indicatorList = indicators.isEmpty
                ? ""
                : "\n<ul class=\"indicators\">\n\(indicators.joined(separator: "\n"))\n</ul>"

            return """
            <section class="card finding" data-analyzer="\(HTMLTemplate.escape(finding.analyzerID))">
            <h3><span class="finding-score \(severity)">\(HTMLTemplate.scoreText(finding.score))/100</span> \(HTMLTemplate.escape(Self.displayName(for: finding.analyzerID))) <span class="muted">[\(HTMLTemplate.escape(finding.analyzerID))]</span></h3>
            <p>\(HTMLTemplate.escape(finding.summary))</p>\(indicatorList)
            </section>
            """
        }

        return """
        <h2>Findings</h2>
        \(sections.joined(separator: "\n"))
        """
    }

    /// Plain inline JavaScript -- no libraries -- that shows or hides an
    /// overlay layer whenever its checkbox changes.
    static let toggleScript = """
    document.querySelectorAll('input[data-layer]').forEach(function (box) {
      box.addEventListener('change', function () {
        document.querySelectorAll('g.layer').forEach(function (group) {
          if (group.getAttribute('data-layer') === box.getAttribute('data-layer')) {
            group.style.display = box.checked ? '' : 'none';
          }
        });
      });
    });
    """

    // MARK: - Helpers

    /// A report "has anomalies" if any analyzer scored above zero.
    static func hasAnomalies(_ report: ForensicReport) -> Bool {
        report.findings.contains { $0.score > 0 }
    }

    static func describe(_ region: Region) -> String {
        "x \(region.x), y \(region.y), \(region.width)\u{00D7}\(region.height) px"
    }

    /// The most regions listed inline under a single indicator. A summary
    /// indicator can carry dozens of cells; all of them are still drawn on
    /// the image, but the text list is capped so it stays readable.
    static let maxListedRegions = 12

    static func regionList(_ regions: [Region]) -> String {
        guard !regions.isEmpty else { return "" }
        let listed = regions.prefix(maxListedRegions).map { "<li class=\"region\">\(describe($0))</li>" }
        let remainder = regions.count - listed.count
        let more = remainder > 0 ? "\n<li class=\"region muted\">and \(remainder) more</li>" : ""
        return "\n<ul class=\"regions\">\n\(listed.joined(separator: "\n"))\(more)\n</ul>"
    }

    static func fileName(of path: String) -> String {
        let components = path.split(whereSeparator: { $0 == "/" || $0 == "\\" })
        return components.last.map(String.init) ?? path
    }

    static let reportStyle = """
    .report-header { display: flex; justify-content: space-between; align-items: center; gap: 16px; flex-wrap: wrap; }
    .report-header .path { margin: 0; }
    .score-block { text-align: right; }
    .score { font-size: 3rem; font-weight: 700; line-height: 1; font-variant-numeric: tabular-nums; }
    .score-max { font-size: 1.2rem; font-weight: 400; color: var(--muted); }
    .verdict { font-weight: 600; text-transform: capitalize; }
    .no-anomalies { font-weight: 600; color: var(--sev-low); }
    .toggles { display: flex; flex-wrap: wrap; gap: 8px 20px; margin: 20px 0 12px; }
    .toggle { display: inline-flex; align-items: center; gap: 6px; cursor: pointer; user-select: none; }
    .swatch { display: inline-block; width: 14px; height: 14px; border-radius: 3px; margin-right: 4px; vertical-align: -2px; }
    .stage { position: relative; display: inline-block; margin: 0; max-width: 100%; line-height: 0; border: 1px solid var(--border); }
    .stage img { display: block; max-width: 100%; height: auto; image-rendering: pixelated; }
    .overlays { position: absolute; top: 0; left: 0; width: 100%; height: 100%; }
    .overlay { fill-opacity: 0.28; stroke-width: 2px; vector-effect: non-scaling-stroke; }
    .image-missing { color: var(--muted); }
    .legend { list-style: none; padding: 0; margin: 12px 0 0; display: flex; flex-wrap: wrap; gap: 6px 20px; }
    .finding { margin-bottom: 12px; }
    .finding h3 { font-size: 1rem; margin: 0 0 6px; }
    .finding p { margin: 0; }
    .finding-score { font-variant-numeric: tabular-nums; margin-right: 6px; }
    .indicators { margin: 8px 0 0; padding-left: 20px; }
    .indicators li { margin-bottom: 4px; }
    .regions { margin: 2px 0 0; padding-left: 18px; font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; font-size: 0.8rem; color: var(--muted); }
    """
}
