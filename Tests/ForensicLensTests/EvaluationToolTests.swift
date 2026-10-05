import XCTest
import BatchProcessing
import ForensicLens
import ImageDecoding
@testable import forensiclens_eval

/// Covers `forensiclens-eval`'s dataset loading, argument parsing, and an
/// end-to-end run over a tiny synthetic labeled dataset written to a
/// temporary directory. Like `BatchCommandTests`, this touches the
/// filesystem but never the network, and commits nothing to the repo.
final class EvaluationToolTests: XCTestCase {
    // MARK: - Folder layout

    func testFolderLayoutLabelsImagesByDirectoryAndScansRecursively() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try write(Fixtures.uniformBuffer(width: 8, height: 8), to: root.appendingPathComponent("authentic/a.bmp"))
        try write(Fixtures.uniformBuffer(width: 8, height: 8), to: root.appendingPathComponent("tampered/Sp/b.jpg"))
        try write(Fixtures.uniformBuffer(width: 8, height: 8), to: root.appendingPathComponent("tampered/CM/c.tif"))
        try Data("not an image".utf8).write(to: root.appendingPathComponent("tampered/notes.txt"))

        let layout = try DatasetLoader.detectLayout(at: root.path)
        XCTAssertEqual(layout, .folders(root: root.path))

        let images = try DatasetLoader.load(layout, extensions: EvalOptions.defaultExtensions)
        XCTAssertEqual(images.filter { $0.label == .authentic }.count, 1)
        XCTAssertEqual(images.filter { $0.label == .tampered }.count, 2)
        XCTAssertFalse(images.contains { $0.path.hasSuffix("notes.txt") })
    }

    func testMissingClassDirectoryIsAClearError() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(Fixtures.uniformBuffer(width: 8, height: 8), to: root.appendingPathComponent("authentic/a.bmp"))

        XCTAssertThrowsError(try DatasetLoader.load(.folders(root: root.path), extensions: ["bmp"])) { error in
            XCTAssertEqual(error as? DatasetError, .missingClassDirectory(root: root.path, name: "tampered"))
            XCTAssertTrue("\(error)".contains("tampered/"))
        }
    }

    func testEmptyClassDirectoryIsAClearError() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(Fixtures.uniformBuffer(width: 8, height: 8), to: root.appendingPathComponent("authentic/a.bmp"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("tampered"), withIntermediateDirectories: true)

        XCTAssertThrowsError(try DatasetLoader.load(.folders(root: root.path), extensions: ["bmp"])) { error in
            guard case .noImages = error as? DatasetError else {
                return XCTFail("expected DatasetError.noImages, got \(error)")
            }
        }
    }

    func testNonexistentDatasetPathIsAClearError() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        XCTAssertThrowsError(try DatasetLoader.detectLayout(at: missing)) { error in
            XCTAssertEqual(error as? DatasetError, .notFound(missing))
        }
    }

    // MARK: - CSV manifest

    func testManifestParsingHandlesHeaderCommentsQuotesAliasesAndRelativePaths() throws {
        let manifest = """
        path,label
        # CASIA-style prefixes work as labels too
        Au/Au_ani_0001.jpg,Au
        "Tp/with, comma.jpg",tp
        /abs/real.bmp,authentic

        dup.bmp,1
        dup.bmp,tampered
        """
        let images = try DatasetLoader.parseManifest(manifest, manifestName: "m.csv", baseDirectory: "/data")

        XCTAssertEqual(images.count, 4)
        XCTAssertEqual(images[0], LabeledImage(path: ("/data" as NSString).appendingPathComponent("Au/Au_ani_0001.jpg"), label: .authentic))
        XCTAssertEqual(images[1], LabeledImage(path: ("/data" as NSString).appendingPathComponent("Tp/with, comma.jpg"), label: .tampered))
        XCTAssertEqual(images[2], LabeledImage(path: "/abs/real.bmp", label: .authentic))
        XCTAssertEqual(images[3].label, .tampered)
    }

    func testManifestErrorsReportTheOffendingLine() {
        XCTAssertThrowsError(try DatasetLoader.parseManifest("a.jpg,authentic\nb.jpg,maybe", manifestName: "m.csv", baseDirectory: "/")) { error in
            XCTAssertEqual(error as? DatasetError, .unknownLabel(manifest: "m.csv", line: 2, label: "maybe"))
        }
        XCTAssertThrowsError(try DatasetLoader.parseManifest("just-a-path.jpg", manifestName: "m.csv", baseDirectory: "/")) { error in
            XCTAssertEqual(error as? DatasetError, .malformedManifestLine(manifest: "m.csv", line: 1, content: "just-a-path.jpg"))
        }
        XCTAssertThrowsError(try DatasetLoader.parseManifest("\"unterminated.jpg,tampered", manifestName: "m.csv", baseDirectory: "/")) { error in
            guard case .malformedManifestLine = error as? DatasetError else {
                return XCTFail("expected malformedManifestLine, got \(error)")
            }
        }
        XCTAssertThrowsError(try DatasetLoader.parseManifest("x.jpg,authentic\nx.jpg,tampered", manifestName: "m.csv", baseDirectory: "/")) { error in
            guard case .conflictingLabels = error as? DatasetError else {
                return XCTFail("expected conflictingLabels, got \(error)")
            }
        }
        XCTAssertThrowsError(try DatasetLoader.parseManifest("path,label\n# nothing here\n", manifestName: "m.csv", baseDirectory: "/")) { error in
            XCTAssertEqual(error as? DatasetError, .emptyManifest("m.csv"))
        }
    }

    // MARK: - Argument parsing

    func testParseAppliesDefaultsAndRejectsConflictingFlags() throws {
        let defaults = try XCTUnwrap(EvalCLI.parse(["--dataset", "data"]))
        XCTAssertEqual(defaults.datasetPath, "data")
        XCTAssertEqual(defaults.threshold, EvalOptions.defaultThreshold)
        XCTAssertFalse(defaults.sweep)

        let sweep = try XCTUnwrap(EvalCLI.parse(["--dataset", "data", "--sweep", "--sweep-step", "2.5", "--csv", "out.csv"]))
        XCTAssertTrue(sweep.sweep)
        XCTAssertEqual(sweep.sweepStep, 2.5)
        XCTAssertEqual(sweep.csvPath, "out.csv")

        XCTAssertNil(try EvalCLI.parse(["--help"]))
        XCTAssertThrowsError(try EvalCLI.parse([])) { XCTAssertEqual($0 as? EvalCLIError, .missingDataset) }
        XCTAssertThrowsError(try EvalCLI.parse(["--dataset", "d", "--threshold", "50", "--sweep"])) {
            XCTAssertEqual($0 as? EvalCLIError, .thresholdWithSweep)
        }
        XCTAssertThrowsError(try EvalCLI.parse(["--dataset", "d", "--csv", "x.csv"])) {
            XCTAssertEqual($0 as? EvalCLIError, .csvWithoutSweep)
        }
        XCTAssertThrowsError(try EvalCLI.parse(["--dataset", "d", "--threshold", "abc"]))
        XCTAssertThrowsError(try EvalCLI.parse(["--dataset", "d", "--threshold", "150"]))
        XCTAssertThrowsError(try EvalCLI.parse(["--dataset"])) { XCTAssertEqual($0 as? EvalCLIError, .missingValue("--dataset")) }
        XCTAssertThrowsError(try EvalCLI.parse(["--dataset", "d", "--bogus"])) { XCTAssertEqual($0 as? EvalCLIError, .unknownArgument("--bogus")) }
    }

    func testMalformedDatasetMakesTheToolExitWithAnErrorInsteadOfCrashing() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let exitCode = await EvalCLI.run(arguments: ["forensiclens-eval", "--dataset", root.path])
        XCTAssertEqual(exitCode, 1)
    }

    // MARK: - End to end

    func testEvaluatorPairsScoresWithLabelsAndSkipsCorruptFiles() async throws {
        let root = try makeSyntheticDataset()
        defer { try? FileManager.default.removeItem(at: root) }

        let dataset = try DatasetLoader.load(.folders(root: root.path), extensions: EvalOptions.defaultExtensions)
        XCTAssertEqual(dataset.count, 5)

        let run = await Evaluator.run(dataset: dataset, analyzer: BatchFileAnalyzer(engine: ForensicLensEngine(config: .default)), maxConcurrency: 2)

        XCTAssertEqual(run.samples.count, 4)
        XCTAssertEqual(run.skipped.count, 1)
        XCTAssertEqual(run.skipped.first?.label, .authentic)
        XCTAssertTrue(run.skipped.first?.path.hasSuffix("corrupt.bmp") ?? false)

        let tamperedScores = run.samples.filter { $0.label == .tampered }.map(\.score)
        let authenticScores = run.samples.filter { $0.label == .authentic }.map(\.score)
        XCTAssertEqual(tamperedScores.count, 2)
        XCTAssertEqual(authenticScores.count, 2)
        // The synthetic copy-move forgeries should stand out from the flat
        // authentic images -- this is what makes the end-to-end metrics
        // below meaningful rather than coincidental.
        XCTAssertGreaterThan(tamperedScores.min() ?? 0, authenticScores.max() ?? 100)
    }

    func testSingleThresholdRunWritesJSONReport() async throws {
        let root = try makeSyntheticDataset()
        defer { try? FileManager.default.removeItem(at: root) }
        let outputPath = root.appendingPathComponent("eval.json").path

        let exitCode = await EvalCLI.run(arguments: [
            "forensiclens-eval", "--dataset", root.path,
            "--output", outputPath,
            "--config", root.appendingPathComponent("does-not-exist.yaml").path
        ])
        XCTAssertEqual(exitCode, 0)

        let report = try JSONDecoder().decode(EvaluationReport.self, from: Data(contentsOf: URL(fileURLWithPath: outputPath)))
        XCTAssertEqual(report.counts, DatasetCounts(authentic: 2, tampered: 2, skipped: 1))
        XCTAssertEqual(report.result.threshold, EvalOptions.defaultThreshold)
        XCTAssertEqual(report.result.confusionMatrix, ConfusionMatrix(truePositives: 2, falsePositives: 0, trueNegatives: 2, falseNegatives: 0))
        XCTAssertEqual(report.result.accuracy, 1)
        XCTAssertEqual(report.samples.count, 4)
        XCTAssertEqual(report.skipped.count, 1)
        XCTAssertEqual(report.result.f1, report.result.confusionMatrix.f1)
    }

    func testSweepRunWritesCSVAndPicksAPerfectThreshold() async throws {
        let root = try makeSyntheticDataset()
        defer { try? FileManager.default.removeItem(at: root) }
        let jsonPath = root.appendingPathComponent("sweep.json").path
        let csvPath = root.appendingPathComponent("sweep.csv").path

        let exitCode = await EvalCLI.run(arguments: [
            "forensiclens-eval", "--dataset", root.path, "--sweep",
            "--sweep-step", "10",
            "--output", jsonPath, "--csv", csvPath,
            "--config", root.appendingPathComponent("does-not-exist.yaml").path
        ])
        XCTAssertEqual(exitCode, 0)

        let csvLines = try String(contentsOfFile: csvPath, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(csvLines.first, "threshold,precision,recall,f1,accuracy,true_positives,false_positives,true_negatives,false_negatives")
        XCTAssertEqual(csvLines.count, 1 + 11)
        XCTAssertTrue(csvLines[1].hasPrefix("0,"))

        let report = try JSONDecoder().decode(SweepReport.self, from: Data(contentsOf: URL(fileURLWithPath: jsonPath)))
        XCTAssertEqual(report.points.count, 11)
        let best = try XCTUnwrap(report.best)
        XCTAssertEqual(best.f1, 1, "the synthetic dataset is separable, so some threshold should classify it perfectly")
    }

    // MARK: - Helpers

    /// Two flat "authentic" images, two copy-move "tampered" images built
    /// with the shared `Fixtures` helpers, and one corrupt file under
    /// `authentic/` to exercise fault isolation.
    private func makeSyntheticDataset() throws -> URL {
        let root = try makeTempDirectory()
        try write(Fixtures.uniformBuffer(width: 32, height: 32, value: 100), to: root.appendingPathComponent("authentic/flat-1.bmp"))
        try write(Fixtures.uniformBuffer(width: 32, height: 32, value: 180), to: root.appendingPathComponent("authentic/flat-2.bmp"))
        try Data([0x00, 0x01, 0x02, 0x03]).write(to: root.appendingPathComponent("authentic/corrupt.bmp"))

        for seed in [UInt64(42), 43] {
            let base = try Fixtures.noiseBuffer(width: 128, height: 128, seed: seed)
            let forged = try Fixtures.pastingPatch(of: 24, from: (x: 8, y: 8), to: (x: 88, y: 88), into: base)
            try write(forged, to: root.appendingPathComponent("tampered/clone-\(seed).bmp"))
        }
        return root
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("forensiclens-eval-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes `buffer` as PPM bytes (decoding goes by magic number, not
    /// extension), creating intermediate directories as needed.
    private func write(_ buffer: PixelBuffer, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(ImageEncoder.encodePPM(buffer)).write(to: url)
    }
}

