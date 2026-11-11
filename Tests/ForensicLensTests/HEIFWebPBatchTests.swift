import XCTest
import BatchProcessing
import ForensicLens
import ImageDecoding
@testable import forensiclens_cli

/// `batch` and `formats` with HEIF/HEIC and WebP files: picked up by
/// default (no `--extensions` needed, any letter case), analyzed through
/// the new decoders, and -- when corrupt -- skipped with a reason like any
/// other unreadable file, without stopping the rest of the batch.
final class HEIFWebPBatchTests: XCTestCase {
    func testBatchPicksUpHEIFAndWebPFilesByDefault() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        for name in ["IMG_0001.HEIC", "photo.heif", "camera.hif", "web.webp", "old.jpg", "notes.txt", "anim.gif"] {
            try Data([0]).write(to: root.appendingPathComponent(name))
        }
        let found = try BatchFileScanner(extensions: Set(CLI.defaultBatchExtensions), recursive: true).scanFiles(in: root.path)
        let names = Set(found.map { ($0 as NSString).lastPathComponent })
        XCTAssertEqual(names, ["IMG_0001.HEIC", "photo.heif", "camera.hif", "web.webp", "old.jpg"])
        XCTAssertTrue(["jpg", "jpeg", "png", "heic", "heif", "hif", "webp"].allSatisfy { CLI.defaultBatchExtensions.contains($0) })
    }

    func testBatchAnalyzesHEIFAndWebPFilesAndSkipsCorruptOnes() async throws {
        let webp = try Fixtures.webpFile(Fixtures.noiseBuffer(width: 64, height: 64, seed: 3))
        let heic = try Fixtures.heifFile(Fixtures.noiseBuffer(width: 64, height: 64, seed: 4), quality: 85)

        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(webp).write(to: root.appendingPathComponent("good.webp"))
        try Data(heic).write(to: root.appendingPathComponent("good.HEIC"))
        try Data(heic.prefix(heic.count / 2)).write(to: root.appendingPathComponent("truncated.heic"))
        try Data(webp.prefix(16) + [UInt8](repeating: 0xAB, count: 64)).write(to: root.appendingPathComponent("garbage.webp"))
        try Data("not an image at all".utf8).write(to: root.appendingPathComponent("renamed.heif"))

        // Per file: what batch mode records for each.
        let analyzer = BatchFileAnalyzer(engine: ForensicLensEngine(config: .default))
        for name in ["good.webp", "good.HEIC"] {
            guard case .analyzed = analyzer.analyze(filePath: root.appendingPathComponent(name).path).outcome else {
                return XCTFail("\(name) should have been analyzed")
            }
        }
        for (name, expected) in [("truncated.heic", "Corrupt"), ("garbage.webp", "Corrupt"), ("renamed.heif", "magic number")] {
            guard case .skipped(let reason) = analyzer.analyze(filePath: root.appendingPathComponent(name).path).outcome else {
                return XCTFail("\(name) should have been skipped")
            }
            XCTAssertTrue(reason.contains(expected), "\(name): \(reason)")
        }

        // The whole command, with no --extensions flag.
        let outputPath = root.appendingPathComponent("report.json").path
        let exitCode = await CLI.run(arguments: [
            "forensiclens-cli", "batch", root.path,
            "--format", "json",
            "--output", outputPath,
            "--config", root.appendingPathComponent("does-not-exist.yaml").path
        ])
        XCTAssertEqual(exitCode, 0)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: outputPath))) as? [String: Any])
        XCTAssertEqual(json["analyzedCount"] as? Int, 2)
        XCTAssertEqual(json["skippedCount"] as? Int, 3)
    }

    func testFormatsCommandListsEveryFormatAndTheCodecLibraries() async throws {
        let report = FormatsCommand.report()
        for expected in ["BMP", "PPM/PGM", "JPEG", "HEIF/HEIC", "WebP", ".heic .heif .hif", ".webp", "not applicable"] {
            XCTAssertTrue(report.contains(expected), "missing \"\(expected)\" in:\n\(report)")
        }
        for library in CodecLibrary.allCases {
            XCTAssertTrue(report.contains(library.isAvailable ? "decoded by \(library.rawValue)" : "NOT AVAILABLE"), report)
        }
        let exitCode = await CLI.run(arguments: ["forensiclens-cli", "formats"])
        XCTAssertEqual(exitCode, 0)
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("forensiclens-heif-webp-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
