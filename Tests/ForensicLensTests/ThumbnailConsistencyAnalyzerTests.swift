import XCTest
import ImageDecoding
@testable import ForensicLens

/// End-to-end coverage of EXIF thumbnail consistency, on complete synthetic
/// JPEG files (see `ThumbnailFixtures.swift`): a camera-style thumbnail of
/// the original scene embedded in EXIF IFD1, in front of a main image that's
/// either the original or an edited version. Also covers every way the check
/// can be not applicable, which must never be scored or crash.
final class ThumbnailConsistencyAnalyzerTests: XCTestCase {
    private let width = 512
    private let height = 384
    private let edit = Region(x: 256, y: 128, width: 128, height: 128)

    private func analyze(_ bytes: [UInt8], config: ForensicLensConfig = .default) throws -> AnalyzerFinding {
        try ThumbnailConsistencyAnalyzer().analyze(ImageData.load(bytes), config: config)
    }

    /// The original scene's thumbnail, in front of `main` (by default the
    /// original scene itself).
    private func cameraFile(main: PixelBuffer? = nil) throws -> [UInt8] {
        let scene = try Fixtures.thumbnailScene(width: width, height: height)
        let thumbnail = try Fixtures.thumbnailJPEG(of: scene, width: 64, height: 48)
        return Fixtures.jpegFile(main: TestJPEGEncoder.encode(main ?? scene, quality: 90), thumbnail: thumbnail)
    }

    // MARK: - Consistent and inconsistent files

    func testUneditedImageMatchesItsThumbnail() throws {
        let bytes = try cameraFile()
        XCTAssertNil(try ImageData.load(bytes).pixels, "JPEG pixels still aren't decoded by ImageData.load")
        let finding = try analyze(bytes)
        XCTAssertEqual(finding.analyzerID, "thumbnail")
        XCTAssertEqual(finding.score, 0)
        XCTAssertTrue(finding.indicators.isEmpty)
        XCTAssertTrue(finding.summary.contains("matches the main image"), finding.summary)
    }

    func testImageEditedAfterTheThumbnailIsFlagged() throws {
        let scene = try Fixtures.thumbnailScene(width: width, height: height)
        let edited = try Fixtures.pastingObject(into: scene, at: edit.x, edit.y, size: edit.width)
        let finding = try analyze(cameraFile(main: edited))

        XCTAssertGreaterThanOrEqual(finding.score, 60)
        let indicator = try XCTUnwrap(finding.indicators.first)
        XCTAssertTrue(indicator.message.hasPrefix("Content mismatch"), indicator.message)
        XCTAssertFalse(finding.indicators.contains { $0.message.hasPrefix("Aspect-ratio mismatch") })
        let region = try XCTUnwrap(indicator.regions.first)
        XCTAssertNotNil(region.intersection(edit), "the least similar area \(region) should overlap the edit")
    }

    func testCroppedImageIsReportedAsReframedNotEdited() throws {
        // Center-cropped from 4:3 to 16:9 after capture, thumbnail untouched.
        let scene = try Fixtures.thumbnailScene(width: width, height: height)
        let cropped = try Fixtures.croppingRows(scene, from: 48, count: 288)
        let finding = try analyze(cameraFile(main: cropped))

        XCTAssertEqual(finding.score, ThumbnailConsistencyAnalyzer.aspectMismatchScore)
        XCTAssertEqual(finding.indicators.count, 1)
        XCTAssertTrue(finding.indicators[0].message.hasPrefix("Aspect-ratio mismatch"), finding.indicators[0].message)
        XCTAssertTrue(finding.indicators[0].message.contains("and matches it"), "a centered crop's content still matches")
    }

    func testLetterboxedCameraThumbnailIsNotAMismatch() throws {
        // A 3:2 photo whose camera stored a 4:3 thumbnail with black bars.
        let scene = try Fixtures.thumbnailScene(width: 480, height: 320)
        let thumbnail = try Fixtures.letterboxedThumbnailJPEG(of: scene, width: 64, height: 48)
        let finding = try analyze(Fixtures.jpegFile(main: TestJPEGEncoder.encode(scene, quality: 90), thumbnail: thumbnail))
        XCTAssertEqual(finding.score, 0, finding.indicators.map(\.message).joined(separator: " | "))
    }

    func testColorImageWithSubsamplingMatchesItsThumbnail() throws {
        let gray = try Fixtures.thumbnailScene(width: 256, height: 192)
        let color = try PixelBuffer(width: 256, height: 192, channels: 3, pixels: gray.pixels.flatMap { [UInt8(clamping: Int($0) + 10), $0, UInt8(clamping: Int($0) - 10)] })
        let thumbnail = try Fixtures.thumbnailJPEG(of: gray, width: 32, height: 24)
        let finding = try analyze(Fixtures.jpegFile(main: TestJPEGEncoder.encode(color, quality: 90, subsampled: true), thumbnail: thumbnail))
        XCTAssertEqual(finding.score, 0, finding.summary)
    }

    func testThresholdControlsTheContentSignal() throws {
        var config = ForensicLensConfig.default
        config.thumbnail.similarityThreshold = 0.999
        XCTAssertGreaterThan(try analyze(cameraFile(), config: config).score, 0, "nothing real matches a thumbnail perfectly")
    }

    // MARK: - Reading the thumbnail

    func testExifReaderExposesTheEmbeddedThumbnail() throws {
        let thumbnail = try Fixtures.thumbnailJPEG(of: Fixtures.thumbnailScene(width: 128, height: 96), width: 32, height: 24)
        let summary = try XCTUnwrap(ExifReader.read(from: Fixtures.jpegFile(main: [0xFF, 0xD8, 0xFF, 0xD9], thumbnail: thumbnail)))
        XCTAssertEqual(summary.make, "TestCam")
        XCTAssertEqual(summary.thumbnail?.compression, 6)
        XCTAssertEqual(summary.thumbnail?.jpegData, thumbnail)
        XCTAssertNil(try XCTUnwrap(ExifReader.read(from: Fixtures.jpegFile(main: [0xFF, 0xD8, 0xFF, 0xD9], thumbnail: nil))).thumbnail)
    }

    // MARK: - Not applicable

    func testImageWithoutThumbnailIsNotApplicable() throws {
        let scene = try Fixtures.thumbnailScene(width: 128, height: 96)
        let finding = try analyze(Fixtures.jpegFile(main: TestJPEGEncoder.encode(scene), thumbnail: nil))
        XCTAssertEqual(finding.score, 0)
        XCTAssertTrue(finding.summary.contains("no embedded EXIF thumbnail"), finding.summary)
        XCTAssertTrue(finding.summary.contains("not applicable"), finding.summary)
    }

    func testImageWithoutExifIsNotApplicable() throws {
        let finding = try analyze(TestJPEGEncoder.encode(Fixtures.thumbnailScene(width: 64, height: 64)))
        XCTAssertEqual(finding.score, 0)
        XCTAssertTrue(finding.summary.contains("no EXIF data"), finding.summary)
    }

    func testCorruptThumbnailIsNotApplicable() throws {
        let scene = try Fixtures.thumbnailScene(width: 256, height: 192)
        let thumbnail = try Fixtures.thumbnailJPEG(of: scene, width: 32, height: 24)
        let finding = try analyze(Fixtures.jpegFile(main: TestJPEGEncoder.encode(scene), thumbnail: Array(thumbnail.prefix(thumbnail.count / 2))))
        XCTAssertEqual(finding.score, 0)
        XCTAssertTrue(finding.summary.contains("couldn't be decoded"), finding.summary)
    }

    func testUncompressedThumbnailIsNotApplicable() throws {
        let scene = try Fixtures.thumbnailScene(width: 128, height: 96)
        let finding = try analyze(Fixtures.jpegFile(main: TestJPEGEncoder.encode(scene), thumbnail: [], thumbnailCompression: 1))
        XCTAssertEqual(finding.score, 0)
        XCTAssertTrue(finding.summary.contains("stored uncompressed"), finding.summary)
    }

    func testUndecodableMainImageIsNotApplicable() throws {
        let thumbnail = try Fixtures.thumbnailJPEG(of: Fixtures.thumbnailScene(width: 128, height: 96), width: 32, height: 24)
        let finding = try analyze(Fixtures.jpegFile(main: [0xFF, 0xD8, 0xFF, 0xD9], thumbnail: thumbnail))
        XCTAssertEqual(finding.score, 0)
        XCTAssertTrue(finding.summary.contains("main image couldn't be decoded"), finding.summary)
    }

    func testNonJPEGIsNotApplicable() throws {
        let finding = try ThumbnailConsistencyAnalyzer().analyze(Fixtures.imageData(from: Fixtures.thumbnailScene(width: 64, height: 64)), config: .default)
        XCTAssertEqual(finding.score, 0)
        XCTAssertTrue(finding.summary.contains("Only JPEG files"), finding.summary)
    }

    // MARK: - Pipeline integration

    func testEngineIncludesTheFindingAndHonorsDisabling() throws {
        let image = try ImageData.load(cameraFile(main: Fixtures.pastingObject(into: Fixtures.thumbnailScene(width: width, height: height), at: edit.x, edit.y, size: edit.width)))
        let report = ForensicLensEngine(config: .default).run(on: image)
        let finding = try XCTUnwrap(report.findings.first { $0.analyzerID == "thumbnail" })
        XCTAssertGreaterThanOrEqual(report.overallScore, finding.score)
        XCTAssertGreaterThan(finding.score, 0)

        var config = ForensicLensConfig.default
        config.thumbnail.enabled = false
        XCTAssertFalse(ForensicLensEngine(config: config).run(on: image).findings.contains { $0.analyzerID == "thumbnail" })
    }
}
