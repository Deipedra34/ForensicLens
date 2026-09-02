import Foundation
import ForensicLens
import ImageDecoding
import BenchmarkReporting

/// Measures how long each analyzer takes against a handful of synthetic
/// image sizes.
///
/// This is invoked by `scripts/benchmark/run.sh`, which just wraps
/// `swift run -c release forensiclens-benchmark` and forwards its
/// arguments -- in particular `--json <path>`, which the CI workflow
/// (`.github/workflows/benchmark.yml`) uses to get a machine-readable copy
/// of the results for `scripts/benchmark/update-readme.sh` to turn into
/// README.md's benchmark table. The `BenchmarkResult` / `BenchmarkReport`
/// types that JSON is encoded as live in the `BenchmarkReporting` library
/// target rather than here, so producer and consumer share one schema.
///
/// The images are generated in-process rather than read from disk (same
/// deterministic noise generator the test suite's fixtures use) so the
/// benchmark has no external inputs to manage and produces the same
/// workload every run.

/// A small, deterministic pseudo-random generator so repeated benchmark
/// runs measure the same workload instead of noise-dependent variance.
struct SeededGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func nextByte() -> UInt8 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return UInt8(truncatingIfNeeded: state >> 24)
    }
}

func makeNoiseImage(width: Int, height: Int) throws -> ImageData {
    var generator = SeededGenerator(seed: UInt64(width * 31 + height))
    var pixels = [UInt8](repeating: 0, count: width * height * 3)
    for i in 0..<pixels.count {
        pixels[i] = generator.nextByte()
    }
    let buffer = try PixelBuffer(width: width, height: height, channels: 3, pixels: pixels)
    let bytes = ImageEncoder.encodePPM(buffer)
    return try ImageData.load(bytes)
}

func timeMilliseconds(_ body: () throws -> Void) rethrows -> Double {
    let start = Date()
    try body()
    return Date().timeIntervalSince(start) * 1000
}

/// Parses `--json <path>` out of argv. Everything else this executable
/// takes is fixed (sizes, analyzers), so this is the only flag worth a
/// real parser for.
func jsonOutputPath(_ arguments: [String]) -> String? {
    guard let flagIndex = arguments.firstIndex(of: "--json"), arguments.index(after: flagIndex) < arguments.count else {
        return nil
    }
    return arguments[arguments.index(after: flagIndex)]
}

let sizes = [(64, 64), (128, 128), (256, 256)]
let config = ForensicLensConfig.default
let ela = ELAAnalyzer()
let metadata = MetadataAnalyzer()
let clone = CloneDetectionAnalyzer()
var jsonResults: [BenchmarkResult] = []

/// Column alignment is done by hand with plain String concatenation
/// instead of `String(format:)`'s `%@` specifier, since that depends on
/// Objective-C bridging that swift-corelibs-foundation doesn't reliably
/// support on Linux.
func padded(_ text: String, to width: Int) -> String {
    text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
}

print("ForensicLens benchmark")
print("=======================")
print(padded("size", to: 12) + padded("pixels", to: 10) + padded("ela (ms)", to: 14) + padded("clone (ms)", to: 14) + "metadata (ms)")

for (width, height) in sizes {
    let image = try makeNoiseImage(width: width, height: height)

    let elaTime = try timeMilliseconds { _ = try ela.analyze(image, config: config) }
    let cloneTime = try timeMilliseconds { _ = try clone.analyze(image, config: config) }
    // MetadataAnalyzer only reads file headers, so it's timed against the
    // same buffer even though this synthetic PPM carries no EXIF -- the
    // point is to show its cost is essentially zero next to pixel analysis.
    let metadataTime = try timeMilliseconds { _ = try metadata.analyze(image, config: config) }

    let row = padded("\(width)x\(height)", to: 12)
        + padded("\(width * height)", to: 10)
        + padded(String(format: "%.2f", elaTime), to: 14)
        + padded(String(format: "%.2f", cloneTime), to: 14)
        + String(format: "%.4f", metadataTime)
    print(row)

    let sizeLabel = "\(width)x\(height)"
    jsonResults.append(BenchmarkResult(analyzer: "ELA", size: sizeLabel, pixels: width * height, milliseconds: elaTime))
    jsonResults.append(BenchmarkResult(analyzer: "Clone Detection", size: sizeLabel, pixels: width * height, milliseconds: cloneTime))
    jsonResults.append(BenchmarkResult(analyzer: "Metadata", size: sizeLabel, pixels: width * height, milliseconds: metadataTime))
}

if let jsonPath = jsonOutputPath(CommandLine.arguments) {
    let isoFormatter = ISO8601DateFormatter()
    let report = BenchmarkReport(generatedAt: isoFormatter.string(from: Date()), results: jsonResults)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(report)
    try data.write(to: URL(fileURLWithPath: jsonPath))
    print("\nWrote JSON results to \(jsonPath)")
}
