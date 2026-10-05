// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "forensiclens",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .library(
            name: "ForensicLens",
            targets: ["ForensicLens"]
        ),
        .executable(
            name: "forensiclens-cli",
            targets: ["forensiclens-cli"]
        ),
        .executable(
            name: "forensiclens-eval",
            targets: ["forensiclens-eval"]
        )
    ],
    dependencies: [],
    targets: [
        // MARK: - C image decoding primitives
        //
        // All non-Swift code lives in this single target. It exposes a small,
        // minimal C API for decoding BMP and PPM/PGM pixel data plus a
        // best-effort baseline JPEG entry point. Nothing outside of
        // `ImageDecoding` ever imports this module directly, which keeps
        // every other part of the package free of C types, unsafe pointers,
        // and platform-specific decoding quirks.
        .target(
            name: "CStbImage",
            path: "Sources/CStbImage",
            publicHeadersPath: "include"
        ),

        // MARK: - Swift image decoding boundary
        //
        // `ImageDecoding` is the ONLY module permitted to `import CStbImage`.
        // It converts raw C buffers into the pure-Swift `PixelBuffer` value
        // type and never leaks C types across its public API.
        .target(
            name: "ImageDecoding",
            dependencies: ["CStbImage"],
            path: "Sources/ImageDecoding"
        ),

        // MARK: - Core forensic analysis library
        .target(
            name: "ForensicLens",
            dependencies: ["ImageDecoding"],
            path: "Sources/ForensicLens"
        ),

        // MARK: - HTML visual report
        //
        // Renders a finished `ForensicReport` as a self-contained HTML page
        // (embedded image, per-analyzer region overlays, breakdown) plus the
        // batch `index.html`. Kept as its own target so report rendering
        // only ever consumes analyzer output and can't reach into how the
        // analyzers compute it. Pure string/data generation -- no
        // platform-specific frameworks.
        .target(
            name: "HTMLReporting",
            dependencies: ["ForensicLens", "ImageDecoding"],
            path: "Sources/HTMLReporting"
        ),

        // MARK: - Shared batch processing
        //
        // Directory scanning, per-file fault isolation, and the bounded
        // concurrent runner behind `forensiclens-cli batch` (including its
        // per-image HTML report hook). Pulled out of
        // the CLI target into its own library so `forensiclens-eval` can
        // reuse the exact same skip-don't-abort behavior on a dataset --
        // an executable target can't depend on another executable target
        // on Windows (see `BenchmarkReporting` below for the same reason).
        .target(
            name: "BatchProcessing",
            dependencies: ["ForensicLens", "ImageDecoding", "HTMLReporting"],
            path: "Sources/BatchProcessing"
        ),

        // MARK: - Command line interface
        .executableTarget(
            name: "forensiclens-cli",
            dependencies: ["ForensicLens", "ImageDecoding", "HTMLReporting", "BatchProcessing"],
            path: "Sources/forensiclens-cli"
        ),

        // MARK: - Benchmark JSON schema
        //
        // The `BenchmarkResult` / `BenchmarkReport` Codable model shared by
        // `forensiclens-benchmark` (which writes it via `--json`) and
        // `forensiclens-readme-updater` (which reads it back). Pulled out
        // into its own library target, rather than having one executable
        // target depend on the other directly, since SwiftPM/lld-link
        // can't link one executable target as a dependency of another on
        // Windows.
        .target(
            name: "BenchmarkReporting",
            path: "Sources/BenchmarkReporting"
        ),

        // MARK: - Benchmark harness
        //
        // Backs the script in scripts/benchmark/. Kept as its own tiny
        // executable target, rather than a shell script alone, so it can
        // call directly into ForensicLensEngine and PixelBuffer instead of
        // shelling out through the CLI's file-based interface.
        .executableTarget(
            name: "forensiclens-benchmark",
            dependencies: ["ForensicLens", "ImageDecoding", "BenchmarkReporting"],
            path: "Sources/forensiclens-benchmark"
        ),

        // MARK: - README benchmark-table updater
        //
        // Backs scripts/benchmark/update-readme.sh. Reads the JSON that
        // `forensiclens-benchmark --json` writes and regenerates the
        // Markdown table between README.md's BENCHMARK-TABLE-START/END
        // markers, leaving the rest of the file untouched. Kept as its own
        // target (rather than folded into the CLI or the benchmark
        // executable) so its table-rendering and marker-replacement logic
        // can be exercised directly from ForensicLensTests.
        .executableTarget(
            name: "forensiclens-readme-updater",
            dependencies: ["BenchmarkReporting"],
            path: "Sources/forensiclens-readme-updater"
        ),

        // MARK: - Accuracy evaluation
        //
        // Runs the full ForensicLensEngine pipeline over a locally stored,
        // labeled dataset of authentic vs. tampered images (e.g. CASIA,
        // obtained separately by the user) and reports precision, recall,
        // F1, accuracy, and a confusion matrix, optionally across a sweep
        // of suspicion-score thresholds. Never downloads anything: it only
        // reads a dataset that's already on disk.
        .executableTarget(
            name: "forensiclens-eval",
            dependencies: ["ForensicLens", "ImageDecoding", "BatchProcessing"],
            path: "Sources/forensiclens-eval"
        ),

        // MARK: - Tests
        .testTarget(
            name: "ForensicLensTests",
            dependencies: ["ForensicLens", "ImageDecoding", "HTMLReporting", "BatchProcessing", "forensiclens-cli", "forensiclens-readme-updater", "forensiclens-eval", "BenchmarkReporting"],
            path: "Tests/ForensicLensTests"
        )
    ]
)
