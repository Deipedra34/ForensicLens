# Using ForensicLens in other repositories

ForensicLens ships two ready-made integrations for running it as an automated check in *your* repository:

- a **GitHub Action** that scans the images a pull request or push adds or changes, and fails the check if any of them looks manipulated;
- a **pre-commit hook** that does the same for staged images before each commit.

You don't need to build or understand ForensicLens to use either one. Both run the same `forensiclens-cli batch` command described in the [README](README.md#cli-usage), with `--fail-threshold` set, so a local run, the hook, and CI all give the same result.

## How the fail threshold works

Every image gets a 0-100 suspicion score. With `--fail-threshold <score>`, `batch` still prints its full report, then exits with status **2** if any image scored **at or above** the threshold. Otherwise it exits 0. Errors, such as a bad flag or a missing path, exit with status **1**, so you can tell the two apart.

Both integrations default to **70**, the score where the CLI's verdict changes to "likely manipulated". For a stricter check, use 45 ("suspicious"). Files that can't be decoded are reported as skipped and never fail the check.

## GitHub Action

Add a workflow such as `.github/workflows/image-forensics.yml`:

```yaml
name: Image forensics

on:
  pull_request:
  push:
    branches: [main]

jobs:
  forensiclens:
    runs-on: ubuntu-latest
    steps:
      - name: Scan changed images with ForensicLens
        uses: Deipedra34/ForensicLens@v1.9.0
        with:
          fail-threshold: "70"   # fail at "likely manipulated" or above
          format: table          # table, json, or csv
          html-report: "true"    # upload per-image HTML reports as an artifact
```

The action checks out your repository by itself. You don't need a separate `actions/checkout` step unless you set `checkout: "false"`.

By default the action scans only the image files **added or modified** by the current pull request (compared with its base branch) or push (compared with the previous commit). It doesn't scan the whole repository, so it stays fast and only flags new content. To scan specific paths instead, set `path`:

```yaml
      - uses: Deipedra34/ForensicLens@v1.9.0
        with:
          path: |
            assets/photos
            docs/**/*.jpg
```

### Inputs

| Input | Default | Description |
|---|---|---|
| `path` | *(empty)* | Files, directories, or glob patterns, one per line. Empty means only images changed in the current PR or push. |
| `fail-threshold` | `70` | Fail if any image scores at or above this (0-100). An empty string means report only, never fail. |
| `format` | `table` | Report format printed to the job log: `table`, `json`, or `csv`. |
| `html-report` | `false` | When `true`, writes an HTML report for every image scoring above 0, plus an `index.html`, and uploads them as a workflow artifact. The upload still happens when the check fails. |
| `extensions` | `jpg,jpeg,png` | Image file extensions to scan. |
| `config` | *(empty)* | Path to a `forensiclens.yaml` in your repository. When empty, `./forensiclens.yaml` is used if it exists, otherwise the built-in defaults. |
| `checkout` | `true` | Set to `false` if your workflow already checked out the repository. Use `fetch-depth: 0` if you rely on the changed-files default. |
| `artifact-name` | `forensiclens-report` | Name of the HTML report artifact. |
| `swift-version` | `6.3.3` | Swift toolchain used to build the CLI on Linux runners. |

### Outputs

| Output | Description |
|---|---|
| `exit-code` | `0` if nothing was flagged (or nothing needed scanning), `2` if an image met the threshold, `1` if the scan itself failed. |
| `scanned-count` | Number of files and directories passed to the scan. |
| `report-dir` | Directory holding the HTML reports, when `html-report` is `true`. |

### Runners and caching

The action runs on **Linux and macOS** runners (`ubuntu-latest`, `macos-latest`). It is a composite action, not a Docker action. It builds `forensiclens-cli` from the action's own source and downloads no prebuilt binaries.

The built binary is cached with `actions/cache`. The cache key covers the runner OS and architecture, the Swift version, and a hash of the action's `Package.swift`, `Package.resolved` (if present) and `Sources/`. After the first run, later runs restore the binary and skip both the Swift toolchain setup and the build. On Linux, the Swift runtime is linked statically so the cached binary runs without a toolchain.

## pre-commit hook

With the [pre-commit](https://pre-commit.com) framework, add this to your repository's `.pre-commit-config.yaml`:

```yaml
repos:
  - repo: https://github.com/Deipedra34/ForensicLens
    rev: v1.9.0
    hooks:
      - id: forensiclens
```

Then run `pre-commit install`. Each commit that stages JPEG or PNG files now runs `forensiclens-cli batch --fail-threshold 70` on just those files, and the commit is blocked if any of them meets the threshold.

To change the threshold or pass any other `batch` flag, use `args`. A `--fail-threshold` given here replaces the default:

```yaml
      - id: forensiclens
        args: [--fail-threshold, "45", --config, forensiclens.yaml]
```

The hook uses pre-commit's `swift` language support. pre-commit builds ForensicLens once into its own cache the first time the hook runs, so a Swift toolchain (5.9 or newer) must be installed on Linux or macOS.

## What gets analyzed today

The integrations analyze exactly what the CLI analyzes. See [Image format support](README.md#image-format-support) in the README. Currently:

- **JPEG** files get metadata (EXIF) analysis. Their pixels aren't decoded yet, so pixel-based analyzers (error level analysis, clone detection, double compression) don't contribute to their score.
- **PNG** files aren't decoded yet. They're reported as skipped and never fail the check.
- **BMP and PPM/PGM** files get every analyzer. Add them with `extensions` in the action, or `args: [--extensions, "bmp,ppm,jpg,jpeg,png"]` in the hook along with matching `types_or`/`files` filters.
