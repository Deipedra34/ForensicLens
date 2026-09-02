import Foundation
import BenchmarkReporting

/// The markers `README.md` uses to bound the auto-generated benchmark
/// table. Kept as constants here (rather than only in the shell wrapper)
/// so the Swift logic and its unit tests share one source of truth for
/// the marker text.
enum BenchmarkTableMarkers {
    static let start = "<!-- BENCHMARK-TABLE-START -->"
    static let end = "<!-- BENCHMARK-TABLE-END -->"
}

/// Errors surfaced while regenerating the benchmark table in `README.md`.
enum ReadmeUpdaterError: Error, CustomStringConvertible {
    case missingMarker(String)
    case duplicateMarker(String)
    case markersOutOfOrder

    var description: String {
        switch self {
        case .missingMarker(let marker):
            return "Could not find marker \"\(marker)\" in the README."
        case .duplicateMarker(let marker):
            return "Marker \"\(marker)\" appears more than once in the README; expected exactly one."
        case .markersOutOfOrder:
            return "\(BenchmarkTableMarkers.end) appears before \(BenchmarkTableMarkers.start) in the README."
        }
    }
}

/// Renders a flat list of benchmark results into the Markdown table that
/// lives between the README's benchmark markers.
///
/// Rows are emitted in the order given, so callers that care about a
/// particular grouping (by image size, say) should sort `results` before
/// calling this.
func renderMarkdownTable(_ results: [BenchmarkResult]) -> String {
    var lines = ["| Analyzer | Image size | Time (ms) |", "| --- | --- | --- |"]
    for result in results {
        lines.append("| \(result.analyzer) | \(result.size) | \(formatMilliseconds(result.milliseconds)) |")
    }
    return lines.joined(separator: "\n")
}

private func formatMilliseconds(_ value: Double) -> String {
    String(format: "%.2f", value)
}

/// Replaces everything between the benchmark markers in `source` with
/// `tableMarkdown`, leaving the markers themselves and everything outside
/// them untouched.
///
/// Rebuilding the whole region from the markers outward -- rather than
/// diffing against whatever text used to be there -- is what makes this
/// idempotent: the result only ever depends on `source`'s marker
/// positions and `tableMarkdown`, never on prior output, so running it
/// twice in a row with the same inputs produces byte-identical README
/// contents both times.
func updateReadmeContents(
    _ source: String,
    tableMarkdown: String,
    startMarker: String = BenchmarkTableMarkers.start,
    endMarker: String = BenchmarkTableMarkers.end
) throws -> String {
    try requireExactlyOneOccurrence(of: startMarker, in: source)
    try requireExactlyOneOccurrence(of: endMarker, in: source)

    guard let startRange = source.range(of: startMarker) else {
        throw ReadmeUpdaterError.missingMarker(startMarker)
    }
    guard let endRange = source.range(of: endMarker) else {
        throw ReadmeUpdaterError.missingMarker(endMarker)
    }
    guard startRange.upperBound <= endRange.lowerBound else {
        throw ReadmeUpdaterError.markersOutOfOrder
    }

    let before = source[..<startRange.upperBound]
    let after = source[endRange.lowerBound...]
    return "\(before)\n\n\(tableMarkdown)\n\n\(after)"
}

private func requireExactlyOneOccurrence(of needle: String, in haystack: String) throws {
    let count = occurrenceCount(of: needle, in: haystack)
    guard count > 0 else { throw ReadmeUpdaterError.missingMarker(needle) }
    guard count == 1 else { throw ReadmeUpdaterError.duplicateMarker(needle) }
}

private func occurrenceCount(of needle: String, in haystack: String) -> Int {
    var count = 0
    var searchRange = haystack.startIndex..<haystack.endIndex
    while let found = haystack.range(of: needle, range: searchRange) {
        count += 1
        searchRange = found.upperBound..<haystack.endIndex
    }
    return count
}
