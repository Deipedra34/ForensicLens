/// Small string-building helpers shared by the single-image report and the
/// batch index page.
///
/// There's deliberately no templating library here: the pages are small,
/// fixed in shape, and built from a handful of named pieces, so plain
/// string interpolation reads fine and keeps `Package.swift` free of
/// dependencies. The one rule every piece follows is that *any* text that
/// didn't come from this file -- analyzer summaries, indicator messages,
/// file paths -- goes through `escape` before it's interpolated.
enum HTMLTemplate {
    /// Escapes `text` for safe use both as element content and inside a
    /// double- or single-quoted attribute value.
    static func escape(_ text: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": escaped += "&amp;"
            case "<": escaped += "&lt;"
            case ">": escaped += "&gt;"
            case "\"": escaped += "&quot;"
            case "'": escaped += "&#39;"
            default: escaped.append(character)
            }
        }
        return escaped
    }

    /// A whole-number 0...100 score, rounded the same way the plain-text
    /// report rounds it, so every output format agrees on the number.
    static func scoreText(_ score: Double) -> String {
        String(Int(score.rounded()))
    }

    /// CSS class for a score's severity band. The bands mirror
    /// `SuspicionScorer`'s verdict cut-offs.
    static func severityClass(_ score: Double) -> String {
        switch score {
        case ..<20: return "sev-low"
        case ..<45: return "sev-minor"
        case ..<70: return "sev-suspicious"
        default: return "sev-high"
        }
    }

    /// Wraps `body` in a complete HTML5 document with the shared
    /// stylesheet (plus any page-specific `extraStyle`) inlined in `<head>`,
    /// so the page never references an external file.
    static func document(title: String, extraStyle: String = "", body: String, script: String = "") -> String {
        let scriptBlock = script.isEmpty ? "" : "\n<script>\n\(script)\n</script>"
        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(title))</title>
        <style>
        \(baseStyle)
        \(extraStyle)
        </style>
        </head>
        <body>
        <main>
        \(body)
        </main>\(scriptBlock)
        </body>
        </html>

        """
    }

    private static let baseStyle = """
    :root {
      --bg: #f7f7f8; --surface: #ffffff; --text: #1d1d22; --muted: #5d5d6a;
      --border: #dcdce2; --sev-low: #2b8a3e; --sev-minor: #b08900;
      --sev-suspicious: #d9480f; --sev-high: #c92a2a;
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --bg: #16161a; --surface: #202026; --text: #ececf1; --muted: #a3a3b2;
        --border: #34343d; --sev-low: #51cf66; --sev-minor: #fcc419;
        --sev-suspicious: #ff922b; --sev-high: #ff6b6b;
      }
    }
    * { box-sizing: border-box; }
    body {
      margin: 0; background: var(--bg); color: var(--text);
      font: 15px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
    }
    main { max-width: 1100px; margin: 0 auto; padding: 24px 16px 48px; }
    h1 { font-size: 1.4rem; margin: 0 0 4px; }
    h2 { font-size: 1.1rem; margin: 32px 0 12px; }
    .muted { color: var(--muted); }
    .path { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; font-size: 0.85rem; word-break: break-all; }
    .card { background: var(--surface); border: 1px solid var(--border); border-radius: 8px; padding: 16px; }
    .sev-low { color: var(--sev-low); }
    .sev-minor { color: var(--sev-minor); }
    .sev-suspicious { color: var(--sev-suspicious); }
    .sev-high { color: var(--sev-high); }
    """
}
