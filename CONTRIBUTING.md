# Contributing to ForensicLens

Thanks for taking a look at this project. A few notes before you dive in.

## Getting set up

You'll need Swift 5.9 or newer. Then:

```sh
swift build
swift test
```

Both should work offline, on macOS or Linux, with no extra setup -- the test suite builds its own synthetic images in-memory, so there's nothing to download or configure.

## Project layout

- `Sources/CStbImage` -- the only C code in the project. Nothing outside `ImageDecoding` should ever import it directly.
- `Sources/ImageDecoding` -- the boundary between C and Swift. Exposes `PixelBuffer` and `ImageData`.
- `Sources/ForensicLens` -- the actual forensics library: the `Analyzer` protocol, the three analyzers, scoring, and config.
- `Sources/forensiclens-cli` -- the command-line tool.
- `Sources/forensiclens-benchmark` -- backs `scripts/benchmark/run.sh`.

## Adding a new analyzer

Conform to the `Analyzer` protocol in `Sources/ForensicLens/Analyzer.swift`, add it to `ForensicLensEngine`'s analyzer list, and give it a section in `ForensicLensConfig` if it needs tunable thresholds. Add a matching `<Name>AnalyzerTests.swift` file using the shared fixtures in `Tests/ForensicLensTests/Fixtures.swift` rather than real image files -- the whole suite is meant to run without touching disk or the network.

## Code style

- No force-unwraps or `try!` in library code (`Sources/ForensicLens`, `Sources/ImageDecoding`). Use typed errors instead.
- Doc comments on public APIs should explain *why*, not just *what* -- especially trade-offs like block size vs. accuracy in clone detection.
- No Apple-only frameworks. Foundation and the standard library only, so everything keeps building on Linux.

## Pull requests

Keep them focused -- one analyzer, one bug fix, one doc pass. Make sure `swift test` passes before opening one.
