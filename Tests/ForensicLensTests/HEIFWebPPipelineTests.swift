import XCTest
import ImageDecoding
@testable import ForensicLens

/// The full engine on real HEIF/HEIC and WebP files with a known planted
/// tamper: the same synthetic forgeries the per-analyzer tests use (a
/// copy-move clone, a PRNU splice, a CFA splice, an edit after the EXIF
/// thumbnail was made), written by libheif/libwebp, then loaded through
/// `ImageData.load` -- the path every CLI command and batch mode takes --
/// and checked for the tamper in the engine's report.
///
/// Lossless WebP is bit-exact, so all four format-agnostic detectors must
/// find exactly what they find on the raw pixels. HEIC is coded as YCbCr:
/// grayscale content (the clone, PRNU, and thumbnail fixtures) survives
/// lossless HEVC essentially unchanged, but the CFA fixture's color
/// demosaicing pattern depends on how the encoder treats chroma, so on HEIC
/// the CFA check is only required to run (see the README's note on lossy
/// formats).
final class HEIFWebPPipelineTests: XCTestCase {
    private let engine = ForensicLensEngine(config: .default)

    private func finding(_ id: String, in report: ForensicReport, file: StaticString = #filePath, line: UInt = #line) throws -> AnalyzerFinding {
        try XCTUnwrap(report.findings.first { $0.analyzerID == id }, "no \(id) finding", file: file, line: line)
    }

    // MARK: - Fixtures

    /// A grayscale noise image with a 24px patch copied from (8,8) to (88,88).
    private func cloned() throws -> PixelBuffer {
        try Fixtures.pastingPatch(of: 24, from: (x: 8, y: 8), to: (x: 88, y: 88),
                                  into: Fixtures.noiseBuffer(width: 128, height: 128, channels: 1, seed: 42))
    }

    private let spliceRegion = Region(x: 128, y: 64, width: 64, height: 64)

    /// A simulated sensor capture with a noise-free block spliced in (see `PRNUAnalyzerTests`).
    private func prnuSpliced() throws -> PixelBuffer {
        let capture = try Fixtures.simulatedCapture(width: 256, height: 256, sensor: Fixtures.sensorPattern(width: 256, height: 256, seed: 11), sceneSeed: 3, noiseSeed: 101)
        return try Fixtures.splicing(.noiseFree, sceneSeed: 3, at: spliceRegion.x, spliceRegion.y, size: spliceRegion.width, into: capture)
    }

    /// A Bayer capture with a block of random pixels spliced in (see `CFAAnalyzerTests`).
    private func cfaSpliced() throws -> PixelBuffer {
        try Fixtures.splicingCFA(.randomPixels(seed: 99), at: spliceRegion.x, spliceRegion.y, size: spliceRegion.width,
                                 into: Fixtures.demosaicedCapture(width: 256, height: 256, sceneSeed: 2, noiseSeed: 5))
    }

    private let edit = Region(x: 256, y: 128, width: 128, height: 128)

    /// The original scene's EXIF thumbnail, and the scene with an object
    /// pasted in afterwards (see `ThumbnailConsistencyAnalyzerTests`).
    private func editedAfterThumbnail() throws -> (main: PixelBuffer, exif: [UInt8]) {
        let scene = try Fixtures.thumbnailScene(width: 512, height: 384)
        let thumbnail = try Fixtures.thumbnailJPEG(of: scene, width: 64, height: 48)
        let edited = try Fixtures.pastingObject(into: scene, at: edit.x, edit.y, size: edit.width)
        return (edited, Fixtures.thumbnailExifTIFF(thumbnail: thumbnail))
    }

    // MARK: - Checks

    private func assertCloneFound(_ bytes: [UInt8], file: StaticString = #filePath, line: UInt = #line) throws {
        let report = engine.run(on: try ImageData.load(bytes))
        let clone = try finding("clone", in: report, file: file, line: line)
        XCTAssertGreaterThan(clone.score, 0, clone.summary, file: file, line: line)
        XCTAssertFalse(clone.indicators.isEmpty, file: file, line: line)
        XCTAssertGreaterThanOrEqual(report.overallScore, clone.score, file: file, line: line)
    }

    private func assertSpliceFound(_ id: String, _ bytes: [UInt8], file: StaticString = #filePath, line: UInt = #line) throws {
        let report = engine.run(on: try ImageData.load(bytes))
        let spliced = try finding(id, in: report, file: file, line: line)
        XCTAssertGreaterThan(spliced.score, 0, spliced.summary, file: file, line: line)
        XCTAssertTrue(spliced.indicators.flatMap(\.regions).contains(spliceRegion), "\(spliced.indicators)", file: file, line: line)
        XCTAssertGreaterThanOrEqual(report.overallScore, spliced.score, file: file, line: line)
    }

    private func assertEditAfterThumbnailFound(_ bytes: [UInt8], file: StaticString = #filePath, line: UInt = #line) throws {
        let report = engine.run(on: try ImageData.load(bytes))
        let thumbnail = try finding("thumbnail", in: report, file: file, line: line)
        XCTAssertGreaterThanOrEqual(thumbnail.score, 60, thumbnail.summary, file: file, line: line)
        let indicator = try XCTUnwrap(thumbnail.indicators.first, file: file, line: line)
        XCTAssertTrue(indicator.message.hasPrefix("Content mismatch"), indicator.message, file: file, line: line)
        let region = try XCTUnwrap(indicator.regions.first, file: file, line: line)
        XCTAssertNotNil(region.intersection(edit), "the least similar area \(region) should overlap the edit", file: file, line: line)
    }

    // MARK: - WebP (lossless, bit-exact)

    func testWebPDecodesTheFixturePixelsExactly() throws {
        let buffer = try cfaSpliced()
        XCTAssertEqual(try ImageData.load(Fixtures.webpFile(buffer)).pixels?.pixels, buffer.pixels)
    }

    func testCloneIsDetectedInAWebPFile() throws {
        try assertCloneFound(Fixtures.webpFile(cloned()))
    }

    func testPRNUSpliceIsDetectedInAWebPFile() throws {
        try assertSpliceFound("prnu", Fixtures.webpFile(prnuSpliced()))
    }

    func testCFASpliceIsDetectedInAWebPFile() throws {
        try assertSpliceFound("cfa", Fixtures.webpFile(cfaSpliced()))
    }

    func testEditAfterTheThumbnailIsDetectedInAWebPFile() throws {
        let fixture = try editedAfterThumbnail()
        try assertEditAfterThumbnailFound(Fixtures.webpFile(fixture.main, exifTIFF: fixture.exif))
    }

    func testUneditedWebPMatchesItsThumbnail() throws {
        let scene = try Fixtures.thumbnailScene(width: 512, height: 384)
        let exif = Fixtures.thumbnailExifTIFF(thumbnail: try Fixtures.thumbnailJPEG(of: scene, width: 64, height: 48))
        let report = engine.run(on: try ImageData.load(Fixtures.webpFile(scene, exifTIFF: exif)))
        let thumbnail = try finding("thumbnail", in: report)
        XCTAssertEqual(thumbnail.score, 0)
        XCTAssertTrue(thumbnail.summary.contains("matches the main image"), thumbnail.summary)
    }

    // MARK: - HEIF/HEIC (lossless)

    func testCloneIsDetectedInAHEICFile() throws {
        try assertCloneFound(Fixtures.heifFile(cloned()))
    }

    func testPRNUSpliceIsDetectedInAHEICFile() throws {
        try assertSpliceFound("prnu", Fixtures.heifFile(prnuSpliced()))
    }

    func testEditAfterTheThumbnailIsDetectedInAHEICFile() throws {
        let fixture = try editedAfterThumbnail()
        try assertEditAfterThumbnailFound(Fixtures.heifFile(fixture.main, exifTIFF: fixture.exif))
    }

    func testCFARunsOnADecodedHEICFile() throws {
        let report = engine.run(on: try ImageData.load(Fixtures.heifFile(cfaSpliced())))
        let cfa = try finding("cfa", in: report)
        XCTAssertFalse(cfa.summary.hasPrefix("Could not run"), cfa.summary)
    }
}
