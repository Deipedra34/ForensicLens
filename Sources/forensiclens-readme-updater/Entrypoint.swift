import Foundation
import BenchmarkReporting

/// Process entry point for `update-readme`.
///
/// Pure logic lives in `ReadmeUpdater.swift` / `BenchmarkResult.swift`;
/// this file only wires it to argv, stdio, and the filesystem. Using
/// `@main` rather than top-level code in a file named `main.swift` keeps
/// `@testable import forensiclens_readme_updater` from firing off a real
/// run (and its `exit()` call) the moment the test binary loads --
/// see `forensiclens-cli`'s `Entrypoint.swift` for the same pattern.
@main
struct Entrypoint {
    static func main() {
        exit(run(arguments: CommandLine.arguments))
    }

    static func run(arguments: [String]) -> Int32 {
        var inputPath: String?
        var readmePath = "README.md"

        var iterator = arguments.dropFirst().makeIterator()
        while let arg = iterator.next() {
            switch arg {
            case "--input":
                guard let value = iterator.next() else {
                    eprint("Error: --input requires a path argument.")
                    printUsage()
                    return 1
                }
                inputPath = value
            case "--readme":
                guard let value = iterator.next() else {
                    eprint("Error: --readme requires a path argument.")
                    printUsage()
                    return 1
                }
                readmePath = value
            case "--help", "-h":
                printUsage()
                return 0
            default:
                eprint("Error: unknown argument \"\(arg)\".")
                printUsage()
                return 1
            }
        }

        guard let inputPath else {
            eprint("Error: --input <path> is required.")
            printUsage()
            return 1
        }

        do {
            let inputData = try Data(contentsOf: URL(fileURLWithPath: inputPath))
            let report = try JSONDecoder().decode(BenchmarkReport.self, from: inputData)
            let table = renderMarkdownTable(report.results)

            let readmeURL = URL(fileURLWithPath: readmePath)
            let currentContents = try String(contentsOf: readmeURL, encoding: .utf8)
            let updatedContents = try updateReadmeContents(currentContents, tableMarkdown: table)

            if updatedContents == currentContents {
                print("\(readmePath) benchmark table already matches \(inputPath); nothing to write.")
            } else {
                try updatedContents.write(to: readmeURL, atomically: true, encoding: .utf8)
                print("Updated benchmark table in \(readmePath) from \(inputPath).")
            }
            return 0
        } catch {
            eprint("Error: \(error)")
            return 1
        }
    }

    private static func eprint(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    private static func printUsage() {
        print("""
        update-readme -- regenerate the benchmark table in README.md

        USAGE:
          update-readme --input <benchmark-results.json> [--readme <path>]

        Reads a JSON benchmark report (as written by
        `forensiclens-benchmark --json <path>`) and replaces the Markdown
        table between the BENCHMARK-TABLE-START/END markers in README.md
        (or the file given via --readme) with a table generated from it.
        Everything outside those markers is left untouched. Running this
        twice in a row with the same input is a no-op the second time.

        A sample report lives at scripts/benchmark/sample-benchmark.json,
        for trying this out without running the real benchmark:

          scripts/benchmark/update-readme.sh \\
            --input scripts/benchmark/sample-benchmark.json \\
            --readme /tmp/README.md
        """)
    }
}
