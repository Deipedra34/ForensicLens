#!/usr/bin/env bash
#
# Regenerates the Markdown table between README.md's
# <!-- BENCHMARK-TABLE-START/END --> markers from a JSON benchmark report
# (as written by `scripts/benchmark/run.sh --json <path>`), leaving the
# rest of the file untouched.
#
# This is a thin trampoline around the forensiclens-readme-updater
# executable target -- the actual table-rendering and marker-replacement
# logic lives in Sources/forensiclens-readme-updater, where it can be unit
# tested from ForensicLensTests. All arguments are forwarded as-is.
#
# Requires --input <path> to a JSON report; --readme <path> defaults to
# README.md. To try this out without running the real benchmark, point
# --input at the sample fixture:
#
#   scripts/benchmark/update-readme.sh --input scripts/benchmark/sample-benchmark.json
#
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

swift build -c release --product forensiclens-readme-updater
swift run -c release forensiclens-readme-updater "$@"
