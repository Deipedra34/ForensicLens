#!/usr/bin/env bash
#
# Builds and runs the ForensicLens benchmark harness (Sources/forensiclens-benchmark)
# in release mode and prints per-analyzer timing across a few synthetic image
# sizes. See README.md's "Benchmarking" section for example output.
#
# Arguments are forwarded to the benchmark executable, so passing
# `--json <path>` here also writes a machine-readable copy of the results
# to that path -- see update-readme.sh, and
# .github/workflows/benchmark.yml, which use it to keep README.md's
# benchmark table current.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

swift build -c release --product forensiclens-benchmark
swift run -c release forensiclens-benchmark "$@"
