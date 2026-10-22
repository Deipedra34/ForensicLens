// swift-tools-version:5.9
import Foundation
import PackageDescription

// The WebAssembly build of ForensicLens, for the browser demo in ../web.
//
// This is a separate package on purpose: it depends on the main package
// (one directory up) by path, so the main Package.swift, its targets, and
// the native macOS/Linux build don't change at all. Build it with
// scripts/wasm/build.sh, which needs a Swift toolchain plus the matching
// Swift SDK for WebAssembly (see README.md, "Web Demo").
//
// A path dependency's package identity is the name of its directory, so
// it's read from disk instead of hard-coded. That way the build works
// whatever the checkout's folder is called.
let mainPackageDirectory = URL(fileURLWithPath: Context.packageDirectory).deletingLastPathComponent()
let mainPackageIdentity = mainPackageDirectory.lastPathComponent

let package = Package(
    name: "forensiclens-wasm",
    dependencies: [
        .package(path: mainPackageDirectory.path)
    ],
    targets: [
        // A WASI "reactor" module: instead of running `main` once and
        // exiting, it's initialized once (`_initialize`) and then exports
        // functions the page's JavaScript calls repeatedly (see Exports.swift).
        // The stack is raised from wasm-ld's 64 KiB default, which deep Swift
        // call chains with large frames can exhaust, and debug info is
        // stripped, since the page downloads the whole module.
        .executableTarget(
            name: "forensiclens-wasm",
            dependencies: [
                .product(name: "ForensicLens", package: mainPackageIdentity)
            ],
            path: "Sources/forensiclens-wasm",
            linkerSettings: [
                .unsafeFlags([
                    "-Xclang-linker", "-mexec-model=reactor",
                    "-Xlinker", "-z", "-Xlinker", "stack-size=1048576",
                    "-Xlinker", "--strip-debug",
                ], .when(platforms: [.wasi]))
            ]
        )
    ]
)
