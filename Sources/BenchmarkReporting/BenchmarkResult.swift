import Foundation

/// One row of benchmark data: a single analyzer's time against a single
/// synthetic image size.
///
/// This is the shared schema between `forensiclens-benchmark` (which
/// produces it via `--json`) and this target's README-updating logic
/// (which consumes it), so the two stay in sync by construction rather
/// than by convention.
public struct BenchmarkResult: Codable, Equatable {
    public let analyzer: String
    public let size: String
    public let pixels: Int
    public let milliseconds: Double

    public init(analyzer: String, size: String, pixels: Int, milliseconds: Double) {
        self.analyzer = analyzer
        self.size = size
        self.pixels = pixels
        self.milliseconds = milliseconds
    }
}

/// The JSON document `forensiclens-benchmark --json <path>` writes and
/// `scripts/benchmark/update-readme.sh` reads.
public struct BenchmarkReport: Codable, Equatable {
    /// ISO 8601 timestamp of when the benchmark run that produced this
    /// report started. Informational only -- nothing in the README-update
    /// path depends on its format.
    public let generatedAt: String
    public let results: [BenchmarkResult]

    public init(generatedAt: String, results: [BenchmarkResult]) {
        self.generatedAt = generatedAt
        self.results = results
    }
}
