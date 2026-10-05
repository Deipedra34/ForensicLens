import Foundation
import BatchProcessing
import ForensicLens

/// Parsed `forensiclens-eval` options.
struct EvalOptions: Equatable {
    /// Matches the score where `SuspicionScorer`'s verdict moves from
    /// "minor anomalies" to "suspicious".
    static let defaultThreshold = 45.0
    static let defaultExtensions: Set<String> = ["jpg", "jpeg", "png", "bmp", "ppm", "pgm", "tif", "tiff"]

    var datasetPath: String
    var threshold = defaultThreshold
    var sweep = false
    var sweepMin = 0.0
    var sweepMax = 100.0
    var sweepStep = 5.0
    var outputPath: String?
    var csvPath: String?
    var configPath = "forensiclens.yaml"
    var extensions = defaultExtensions
    var maxConcurrency = max(1, ProcessInfo.processInfo.activeProcessorCount)
}

enum EvalCLIError: Error, Equatable, CustomStringConvertible {
    case missingValue(String)
    case invalidNumber(flag: String, value: String)
    case unknownArgument(String)
    case missingDataset
    case thresholdWithSweep
    case csvWithoutSweep
    case emptyExtensions
    case noImagesAnalyzed(skipped: Int)

    var description: String {
        switch self {
        case .missingValue(let flag):
            return "\(flag) requires a value."
        case .invalidNumber(let flag, let value):
            return "\(flag) got \"\(value)\", which is not a valid value for it."
        case .unknownArgument(let arg):
            return "unknown argument \"\(arg)\"."
        case .missingDataset:
            return "--dataset <path> is required."
        case .thresholdWithSweep:
            return "--threshold and --sweep cannot be combined; use --sweep-min/--sweep-max/--sweep-step to set the sweep range."
        case .csvWithoutSweep:
            return "--csv is only available with --sweep."
        case .emptyExtensions:
            return "--extensions must list at least one extension."
        case .noImagesAnalyzed(let skipped):
            return "none of the dataset's images could be analyzed (\(skipped) skipped), so no metrics can be computed."
        }
    }
}

/// Argument parsing and orchestration for `forensiclens-eval`. Dataset
/// walking lives in `DatasetLoader`, the analysis loop in `Evaluator`, and
/// the metric math in `ClassificationMetrics.swift`; this type only wires
/// them to argv, stdio, and output files.
enum EvalCLI {
    static func run(arguments: [String]) async -> Int32 {
        let options: EvalOptions
        do {
            guard let parsed = try parse(Array(arguments.dropFirst())) else {
                printUsage()
                return 0
            }
            options = parsed
        } catch {
            eprint("Error: \(error)")
            printUsage()
            return 1
        }

        do {
            try await evaluate(options)
            return 0
        } catch {
            eprint("Error: \(error)")
            return 1
        }
    }

    /// Returns `nil` when help was requested.
    static func parse(_ arguments: [String]) throws -> EvalOptions? {
        var datasetPath: String?
        var options = EvalOptions(datasetPath: "")
        var thresholdGiven = false

        var iterator = arguments.makeIterator()
        func value(for flag: String) throws -> String {
            guard let next = iterator.next() else { throw EvalCLIError.missingValue(flag) }
            return next
        }
        func number(for flag: String) throws -> Double {
            let raw = try value(for: flag)
            guard let parsed = Double(raw), parsed.isFinite else {
                throw EvalCLIError.invalidNumber(flag: flag, value: raw)
            }
            return parsed
        }

        while let arg = iterator.next() {
            switch arg {
            case "--help", "-h":
                return nil
            case "--dataset":
                datasetPath = try value(for: arg)
            case "--threshold":
                let threshold = try number(for: arg)
                guard (0...100).contains(threshold) else {
                    throw EvalCLIError.invalidNumber(flag: arg, value: String(threshold))
                }
                options.threshold = threshold
                thresholdGiven = true
            case "--sweep":
                options.sweep = true
            case "--sweep-min":
                options.sweepMin = try number(for: arg)
            case "--sweep-max":
                options.sweepMax = try number(for: arg)
            case "--sweep-step":
                options.sweepStep = try number(for: arg)
            case "--output":
                options.outputPath = try value(for: arg)
            case "--csv":
                options.csvPath = try value(for: arg)
            case "--config":
                options.configPath = try value(for: arg)
            case "--extensions":
                options.extensions = Set(
                    try value(for: arg)
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                        .filter { !$0.isEmpty }
                )
                guard !options.extensions.isEmpty else { throw EvalCLIError.emptyExtensions }
            case "--max-concurrency":
                let raw = try value(for: arg)
                guard let parsed = Int(raw), parsed > 0 else {
                    throw EvalCLIError.invalidNumber(flag: arg, value: raw)
                }
                options.maxConcurrency = parsed
            default:
                throw EvalCLIError.unknownArgument(arg)
            }
        }

        guard let datasetPath else { throw EvalCLIError.missingDataset }
        options.datasetPath = datasetPath
        if options.sweep && thresholdGiven { throw EvalCLIError.thresholdWithSweep }
        if !options.sweep && options.csvPath != nil { throw EvalCLIError.csvWithoutSweep }
        return options
    }

    static func evaluate(_ options: EvalOptions) async throws {
        // Validate the sweep range before spending any time on analysis.
        let thresholds = options.sweep
            ? try ThresholdSweep.thresholds(min: options.sweepMin, max: options.sweepMax, step: options.sweepStep)
            : []

        let config = try ConfigLoader.load(contentsOfFile: options.configPath)
        let layout = try DatasetLoader.detectLayout(at: options.datasetPath)
        let dataset = try DatasetLoader.load(layout, extensions: options.extensions)

        let analyzer = BatchFileAnalyzer(engine: ForensicLensEngine(config: config))
        let run = await Evaluator.run(
            dataset: dataset,
            analyzer: analyzer,
            maxConcurrency: options.maxConcurrency,
            onFileComplete: BatchRunner.logProgressToStandardError
        )
        guard !run.samples.isEmpty else { throw EvalCLIError.noImagesAnalyzed(skipped: run.skipped.count) }

        if options.sweep {
            let report = SweepReport(dataset: options.datasetPath, run: run, thresholds: thresholds)
            print(EvaluationReportFormatter.text(report))
            if let outputPath = options.outputPath {
                try write(EvaluationReportFormatter.json(report), to: outputPath)
            }
            if let csvPath = options.csvPath {
                try write(EvaluationReportFormatter.csv(report), to: csvPath)
            }
        } else {
            let report = EvaluationReport(dataset: options.datasetPath, run: run, threshold: options.threshold)
            print(EvaluationReportFormatter.text(report))
            if let outputPath = options.outputPath {
                try write(EvaluationReportFormatter.json(report), to: outputPath)
            }
        }
    }

    private static func write(_ contents: String, to path: String) throws {
        do {
            try contents.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            throw OutputError(path: path, underlying: "\(error)")
        }
    }

    private struct OutputError: Error, CustomStringConvertible {
        let path: String
        let underlying: String
        var description: String { "could not write \"\(path)\": \(underlying)" }
    }

    private static func eprint(_ message: String) {
        guard let data = (message + "\n").data(using: .utf8) else { return }
        FileHandle.standardError.write(data)
    }

    private static func printUsage() {
        print("""
        forensiclens-eval -- measure ForensicLens's detection accuracy on a labeled dataset

        USAGE:
          forensiclens-eval --dataset <path> [--threshold <score>] [options]
          forensiclens-eval --dataset <path> --sweep [sweep options] [options]

        DATASET LAYOUT (--dataset):
          A directory containing authentic/ and tampered/ subdirectories
          (each scanned recursively), or a CSV manifest file with one
          "path,label" row per image (label: authentic or tampered;
          relative paths resolve against the manifest's directory).
          Nothing is ever downloaded: the dataset must already be on disk.

        OPTIONS:
          --threshold <score>    Flag an image when its 0-100 suspicion score is at
                                  least this value. Defaults to \(Int(EvalOptions.defaultThreshold)).
          --sweep                Evaluate a range of thresholds and report which
                                  one maximizes F1. Cannot combine with --threshold.
          --sweep-min <score>    Lowest threshold in the sweep. Defaults to 0.
          --sweep-max <score>    Highest threshold in the sweep. Defaults to 100.
          --sweep-step <n>       Distance between sweep thresholds. Defaults to 5.
          --output <path>        Also write the report as JSON to this file.
          --csv <path>           (--sweep only) Write one row per threshold as CSV.
          --config <path>        Path to a forensiclens.yaml config file. Defaults to
                                  ./forensiclens.yaml; missing files fall back to
                                  built-in defaults.
          --extensions <list>    Comma-separated extensions to pick up in the folder
                                  layout. Defaults to "\(EvalOptions.defaultExtensions.sorted().joined(separator: ","))".
          --max-concurrency <n>  Maximum images analyzed at once. Defaults to the
                                  number of available CPU cores.

        EXAMPLES:
          forensiclens-eval --dataset ~/datasets/casia2-prepared
          forensiclens-eval --dataset ~/datasets/casia2-prepared --threshold 30 --output eval.json
          forensiclens-eval --dataset manifest.csv --sweep --sweep-step 2.5 --csv sweep.csv
        """)
    }
}
