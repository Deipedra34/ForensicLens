import Foundation
import ForensicLens
import ImageDecoding

/// Command-line front end for the ForensicLens library.
///
/// This is a hand-rolled argument parser rather than a dependency on
/// swift-argument-parser: the surface area here is small (a subcommand, an
/// image path, and two flags), and keeping `Package.swift` free of
/// dependencies keeps the whole project buildable offline with nothing
/// beyond the Swift toolchain itself.
enum CLI {
    static func run(arguments: [String]) -> Int32 {
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

    private static func eprint(_ message: String) {
        guard let data = (message + "\n").data(using: .utf8) else { return }
        FileHandle.standardError.write(data)
    }

    /// Flags this CLI recognizes that take no following value.
    private static let valuelessFlags: Set<String> = ["--json"]

    private static func parseArguments(_ arguments: ArraySlice<String>) -> (positionals: [String], flags: Set<String>, options: [String: String]) {
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
        return (positionals, flags, options)
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

        COMMANDS:
          report      Run every enabled analyzer and print a combined report.
          ela         Run only Error Level Analysis.
          metadata    Run only EXIF/metadata analysis.
          clone       Run only copy-move (clone) detection.
          help        Show this message.

        OPTIONS:
          --json           Print the report as JSON instead of plain text.
          --config <path>  Path to a forensiclens.yaml config file.
                            Defaults to ./forensiclens.yaml; missing files
                            fall back to built-in defaults.

        EXAMPLES:
          forensiclens-cli report photo.bmp
          forensiclens-cli ela photo.bmp --json
          forensiclens-cli clone photo.ppm --config custom.yaml
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

exit(CLI.run(arguments: CommandLine.arguments))
