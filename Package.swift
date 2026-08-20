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

        // MARK: - Command line interface
        .executableTarget(
            name: "forensiclens-cli",
            dependencies: ["ForensicLens", "ImageDecoding"],
            path: "Sources/forensiclens-cli"
        ),

        // MARK: - Benchmark harness
        //
        // Backs the script in scripts/benchmark/. Kept as its own tiny
        // executable target, rather than a shell script alone, so it can
        // call directly into ForensicLensEngine and PixelBuffer instead of
        // shelling out through the CLI's file-based interface.
        .executableTarget(
            name: "forensiclens-benchmark",
            dependencies: ["ForensicLens", "ImageDecoding"],
            path: "Sources/forensiclens-benchmark"
        ),

        // MARK: - Tests
        .testTarget(
            name: "ForensicLensTests",
            dependencies: ["ForensicLens", "ImageDecoding"],
            path: "Tests/ForensicLensTests"
        )
    ]
)
