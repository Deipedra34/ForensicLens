#!/usr/bin/env bash
#
# Builds and runs the ForensicLens benchmark harness (Sources/forensiclens-benchmark)
# in release mode and prints per-analyzer timing across a few synthetic image
# sizes. See README.md's "Benchmarking" section for example output.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

swift build -c release --product forensiclens-benchmark
swift run -c release forensiclens-benchmark
