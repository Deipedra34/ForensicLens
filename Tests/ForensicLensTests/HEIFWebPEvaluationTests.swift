import XCTest
import BatchProcessing
import ForensicLens
import ImageDecoding
@testable import forensiclens_eval

/// `forensiclens-eval` with HEIF/HEIC and WebP images in a CASIA-style
/// dataset: picked up by the default extensions like every other format,
/// scored through the new decoders, and a corrupt one skipped and listed
/// rather than aborting the run.
final class HEIFWebPEvaluationTests: XCTestCase {
    func testDefaultExtensionsIncludeHEIFAndWebP() {
        for ext in ["heic", "heif", "hif", "webp", "jpg", "png", "bmp", "tif"] {
            XCTAssertTrue(EvalOptions.defaultExtensions.contains(ext), ext)
        }
    }

    func testDatasetWithHEIFAndWebPImagesIsLoadedAndCorruptOnesSkipped() async throws {
        let authentic = try Fixtures.noiseBuffer(width: 128, height: 128, channels: 1, seed: 21)
        let tampered = try Fixtures.pastingPatch(of: 24, from: (x: 8, y: 8), to: (x: 88, y: 88),
                                                 into: Fixtures.noiseBuffer(width: 128, height: 128, channels: 1, seed: 22))
        let authenticWebP = try Fixtures.webpFile(authentic)
        let tamperedWebP = try Fixtures.webpFile(tampered)
        let tamperedHEIC = try Fixtures.heifFile(tampered)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("forensiclens-heif-webp-eval-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for directory in ["authentic", "tampered"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        try Data(authenticWebP).write(to: root.appendingPathComponent("authentic/a.webp"))
        try Data(tamperedHEIC.prefix(tamperedHEIC.count / 2)).write(to: root.appendingPathComponent("authentic/broken.HEIC"))
        try Data(tamperedWebP).write(to: root.appendingPathComponent("tampered/b.webp"))
        try Data(tamperedHEIC).write(to: root.appendingPathComponent("tampered/c.heic"))

        let dataset = try DatasetLoader.load(.folders(root: root.path), extensions: EvalOptions.defaultExtensions)
        XCTAssertEqual(dataset.count, 4)

        let run = await Evaluator.run(dataset: dataset, analyzer: BatchFileAnalyzer(engine: ForensicLensEngine(config: .default)), maxConcurrency: 2)
        XCTAssertEqual(run.samples.count, 3)
        XCTAssertEqual(run.skipped.count, 1)
        XCTAssertTrue(run.skipped.first?.path.hasSuffix("broken.HEIC") ?? false)
        XCTAssertTrue(run.skipped.first?.reason.contains("Corrupt") ?? false, "\(run.skipped)")

        let tamperedScores = run.samples.filter { $0.label == .tampered }.map(\.score)
        let authenticScores = run.samples.filter { $0.label == .authentic }.map(\.score)
        XCTAssertEqual(tamperedScores.count, 2)
        XCTAssertGreaterThan(tamperedScores.min() ?? 0, authenticScores.max() ?? 100,
                             "the copy-move forgeries should stand out after decoding")
    }
}
