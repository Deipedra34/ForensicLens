import Foundation
import ForensicLens
import ImageDecoding

/// Command-line front end for the ForensicLens library.
///
/// This is a hand-rolled argument parser rather than a dependency on
/// swift-argument-parser: the surface area here is small (a handful of
/// subcommands and flags), and keeping `Package.swift` free of
/// dependencies keeps the whole project buildable offline with nothing
/// beyond the Swift toolchain itself.
enum CLI {
    static func run(arguments: [String]) async -> Int32 {
        guard arguments.count > 1 else {
            printUsage()
            return 1
        }

        let command = arguments[1]
        if command == "--help" || command == "-h" || command == "help" {
            printUsage()
            return 0
        }

        let parsed = parseArguments(arguments.dropFirst(2))

        if command == "batch" {
            return await runBatch(parsed)
        }

        guard let imagePath = parsed.positionals.first else {
            eprint("Error: missing <image-path> argument.")
            printUsage()
            return 1
        }

        let jsonOutput = parsed.flags.contains("--json")
        let configPath = parsed.options["--config"] ?? "forensiclens.yaml"

        do {
            let config = try ConfigLoader.load(contentsOfFile: configPath)
            let rawBytes = try readFile(imagePath)
            let image = try ImageData.load(rawBytes)
            let engine = ForensicLensEngine(config: config)

            let only: Set<String>?
            switch command {
            case "report":
                only = nil
            case "ela", "metadata", "clone":
                only = [command]
            default:
                eprint("Error: unknown command \"\(command)\".")
                printUsage()
                return 1
            }

            let report = engine.run(on: image, only: only)
            if jsonOutput {
                print(try jsonString(for: report))
            } else {
                print(report.textReport)
            }
            return 0
        } catch {
            eprint("Error: \(error)")
            return 1
        }
    }

    // MARK: - batch subcommand

    /// Handles `forensiclens-cli batch <directory> [options]`: scans a
    /// directory for images, runs the same `ForensicLensEngine` pipeline
    /// used by the single-image commands above against every one of them
    /// concurrently, and writes out a combined report.
    ///
    /// Broken into its own function (rather than folded into `run`) since
    /// it's a genuinely different flow -- a directory positional instead of
    /// an image path, its own flag set, and an async pipeline -- not just
    /// another case of the single-image switch above it.
    private static func runBatch(_ parsed: ParsedArguments) async -> Int32 {
        guard let directory = parsed.positionals.first else {
            eprint("Error: missing <directory> argument.")
            printUsage()
            return 1
        }

        let recursive = !parsed.flags.contains("--no-recursive")

        let extensions = Set(
            (parsed.options["--extensions"] ?? "jpg,jpeg,png")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty }
        )
        guard !extensions.isEmpty else {
            eprint("Error: --extensions must list at least one extension.")
            return 1
        }

        let maxConcurrency: Int
        if let raw = parsed.options["--max-concurrency"] {
            guard let value = Int(raw), value > 0 else {
                eprint("Error: --max-concurrency must be a positive integer, got \"\(raw)\".")
                return 1
            }
            maxConcurrency = value
        } else {
            maxConcurrency = max(1, ProcessInfo.processInfo.activeProcessorCount)
        }

        let formatRaw = parsed.options["--format"] ?? "text"
        guard let format = BatchOutputFormat(rawValue: formatRaw) else {
            eprint("Error: unknown format \"\(formatRaw)\". Use text, json, or csv.")
            return 1
        }

        let configPath = parsed.options["--config"] ?? "forensiclens.yaml"

        let config: ForensicLensConfig
        do {
            config = try ConfigLoader.load(contentsOfFile: configPath)
        } catch {
            eprint("Error: \(error)")
            return 1
        }

        let files: [String]
        do {
            files = try BatchFileScanner(extensions: extensions, recursive: recursive).scanFiles(in: directory)
        } catch {
            eprint("Error: \(error)")
            return 1
        }

        guard !files.isEmpty else {
            eprint("No matching image files found in \"\(directory)\" (extensions: \(extensions.sorted().joined(separator: ", "))).")
            return 1
        }

        let analyzer = BatchFileAnalyzer(engine: ForensicLensEngine(config: config))
        let results = await BatchRunner.run(files: files, analyzer: analyzer, maxConcurrency: maxConcurrency, onFileComplete: reportBatchProgress)

        let report = BatchReport(directory: directory, results: results)
        let rendered: String
        do {
            rendered = try BatchReportFormatter.render(report, as: format)
        } catch {
            eprint("Error: could not render report: \(error)")
            return 1
        }

        if let outputPath = parsed.options["--output"] {
            do {
                try rendered.write(toFile: outputPath, atomically: true, encoding: .utf8)
            } catch {
                eprint("Error: could not write output file \"\(outputPath)\": \(error)")
                return 1
            }
        } else {
            print(rendered)
        }

        return 0
    }

    /// `BatchRunner`'s per-file completion callback: logs a warning for a
    /// skipped file immediately (rather than only surfacing it in the
    /// final report), then updates a "N/total processed" progress line.
    /// Everything here goes to stderr, so it never interferes with the
    /// report -- written to stdout or `--output` -- that `runBatch` emits
    /// once the whole batch finishes.
    @Sendable
    private static func reportBatchProgress(result: BatchAnalysisResult, completed: Int, total: Int) {
        if case .skipped(let reason) = result.outcome {
            eprint("warning: skipping \(result.filePath): \(reason)")
        }
        let progressLine = "\r\(completed)/\(total) processed" + (completed == total ? "\n" : "")
        guard let data = progressLine.data(using: .utf8) else { return }
        FileHandle.standardError.write(data)
    }

    // MARK: - shared helpers

    private static func eprint(_ message: String) {
        guard let data = (message + "\n").data(using: .utf8) else { return }
        FileHandle.standardError.write(data)
    }

    /// Flags this CLI recognizes that take no following value.
    private static let valuelessFlags: Set<String> = ["--json", "--no-recursive"]

    struct ParsedArguments {
        let positionals: [String]
        let flags: Set<String>
        let options: [String: String]
    }

    private static func parseArguments(_ arguments: ArraySlice<String>) -> ParsedArguments {
        var positionals: [String] = []
        var flags: Set<String> = []
        var options: [String: String] = [:]

        var iterator = arguments.makeIterator()
        while let arg = iterator.next() {
            guard arg.hasPrefix("--") else {
                positionals.append(arg)
                continue
            }
            if let equalsIndex = arg.firstIndex(of: "=") {
                let key = String(arg[arg.startIndex..<equalsIndex])
                let value = String(arg[arg.index(after: equalsIndex)...])
                options[key] = value
            } else if valuelessFlags.contains(arg) {
                flags.insert(arg)
            } else if let value = iterator.next() {
                options[arg] = value
            } else {
                flags.insert(arg)
            }
        }
        return ParsedArguments(positionals: positionals, flags: flags, options: options)
    }

    private static func readFile(_ path: String) throws -> [UInt8] {
        guard let data = FileManager.default.contents(atPath: path) else {
            throw CLIError.fileNotFound(path)
        }
        return [UInt8](data)
    }

    private static func jsonString(for report: ForensicReport) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        return String(decoding: data, as: UTF8.self)
    }

    private static func printUsage() {
        print("""
        ForensicLens -- image manipulation forensics

        USAGE:
          forensiclens-cli <command> <image-path> [--json] [--config <path>]
          forensiclens-cli batch <directory> [options]

        COMMANDS:
          report      Run every enabled analyzer and print a combined report.
          ela         Run only Error Level Analysis.
          metadata    Run only EXIF/metadata analysis.
          clone       Run only copy-move (clone) detection.
          batch       Scan a directory of images and print one summary report.
          help        Show this message.

        OPTIONS (report / ela / metadata / clone):
          --json           Print the report as JSON instead of plain text.
          --config <path>  Path to a forensiclens.yaml config file.
                            Defaults to ./forensiclens.yaml; missing files
                            fall back to built-in defaults.

        OPTIONS (batch):
          --no-recursive        Only scan the top-level directory, skip subdirectories.
          --extensions <list>   Comma-separated list of file extensions to treat as
                                 images. Defaults to "jpg,jpeg,png".
          --max-concurrency <n> Maximum number of images analyzed at once. Defaults
                                 to the number of available CPU cores.
          --format <fmt>        Report format: text (default), json, or csv.
          --output <path>       Write the report to a file instead of stdout.
          --config <path>       Same as above.

        EXAMPLES:
          forensiclens-cli report photo.bmp
          forensiclens-cli ela photo.bmp --json
          forensiclens-cli clone photo.ppm --config custom.yaml
          forensiclens-cli batch photos/
          forensiclens-cli batch photos/ --no-recursive --extensions bmp,ppm
          forensiclens-cli batch photos/ --format json --output report.json
        """)
    }
}

enum CLIError: Error, CustomStringConvertible {
    case fileNotFound(String)

    var description: String {
        switch self {
        case .fileNotFound(let path):
            return "Could not read file at \"\(path)\"."
        }
    }
}
