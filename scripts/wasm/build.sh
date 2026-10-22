#!/usr/bin/env bash
# Builds the ForensicLens WebAssembly module and copies it to
# web/forensiclens.wasm, where the demo page loads it from.
#
# Requirements (see README.md, "Web Demo"):
#   - A Swift toolchain, 6.2 or newer.
#   - The Swift SDK for WebAssembly matching that toolchain *exactly*,
#     installed with `swift sdk install <url> --checksum <sha256>` (the URL
#     and checksum for each release are listed at
#     https://www.swift.org/documentation/articles/wasm-getting-started.html).
#   - Optional: `wasm-opt` from Binaryen on PATH, to shrink the module.
#
# Usage:
#   scripts/wasm/build.sh                  # auto-detect the installed Wasm SDK
#   SWIFT_SDK=<id> scripts/wasm/build.sh   # or name one from `swift sdk list`
#   WASM_OPT=0 scripts/wasm/build.sh       # skip wasm-opt even if installed
#
# This builds the separate package in wasm/, which depends on the main
# package by path. Nothing in the main package's native build is touched.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
package_path="$repo_root/wasm"
output="$repo_root/web/forensiclens.wasm"

if ! command -v swift >/dev/null 2>&1; then
  echo "error: swift not found on PATH. Install a Swift toolchain (6.2 or newer) first." >&2
  exit 1
fi

sdk="${SWIFT_SDK:-}"
if [ -z "$sdk" ]; then
  # Prefer the full (non-Embedded) WASI SDK: the analyzers need Foundation,
  # which the Embedded Swift subset doesn't have.
  sdk="$(swift sdk list 2>/dev/null | grep -i 'wasm' | grep -vi 'embedded' | head -n 1 || true)"
fi
if [ -z "$sdk" ]; then
  echo "error: no Swift SDK for WebAssembly is installed." >&2
  echo "Install the one matching \`swift --version\` with:" >&2
  echo "  swift sdk install <artifactbundle URL> --checksum <sha256>" >&2
  echo "(URL and checksum: https://www.swift.org/documentation/articles/wasm-getting-started.html)" >&2
  exit 1
fi
echo "Using Swift SDK: $sdk"

swift build --package-path "$package_path" -c release --swift-sdk "$sdk" --product forensiclens-wasm
bin_path="$(swift build --package-path "$package_path" -c release --swift-sdk "$sdk" --show-bin-path)"
module="$bin_path/forensiclens-wasm.wasm"
if [ ! -f "$module" ]; then
  echo "error: build finished but $module was not found." >&2
  exit 1
fi

cp "$module" "$output"
if [ "${WASM_OPT:-1}" != "0" ] && command -v wasm-opt >/dev/null 2>&1; then
  echo "Optimizing with wasm-opt..."
  # The feature flags match what the Swift compiler emits for WASI and every
  # current browser supports. If this wasm-opt is too old for them, keep the
  # unoptimized module rather than failing the build.
  if ! wasm-opt -O2 --strip-debug --strip-producers --enable-bulk-memory --enable-sign-ext --enable-mutable-globals \
      --enable-nontrapping-float-to-int --enable-reference-types "$module" -o "$output.tmp"; then
    echo "warning: wasm-opt failed; keeping the unoptimized module." >&2
    rm -f "$output.tmp"
  else
    mv "$output.tmp" "$output"
  fi
fi

size_bytes="$(wc -c < "$output" | tr -d ' ')"
echo "Wrote $output ($((size_bytes / 1024 / 1024)) MiB)."
echo "Serve the page with:  python3 -m http.server --directory \"$repo_root/web\" 8000"
