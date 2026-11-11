import XCTest
import ImageDecoding
@testable import ForensicLens

/// EXIF from HEIF and WebP files goes through the same `ExifReader` (and so
/// the same `MetadataAnalyzer` and thumbnail checks) as JPEG. Most of these
/// tests use hand-assembled containers and need no codec library at all:
/// finding the EXIF block is pure Swift, and metadata never needs pixels.
final class HEIFWebPMetadataTests: XCTestCase {
    private let tiff = Fixtures.cameraExifTIFF(make: "PhoneMaker")

    // MARK: - HEIF Exif item (no codec library needed)

    func testExifItemStoredInMdatIsFound() throws {
        let bytes = Fixtures.heifContainer(exifItem: Fixtures.heifExifItem(tiff))
        XCTAssertEqual(ImageFormat.detect(from: bytes), .heif)
        XCTAssertEqual(ContainerMetadata.exifTIFF(in: bytes), tiff)
        XCTAssertEqual(ExifReader.read(from: bytes)?.make, "PhoneMaker")
        XCTAssertEqual(ExifReader.read(from: bytes)?.model, "Model X")
    }

    func testExifItemStoredInIdatIsFound() {
        let bytes = Fixtures.heifContainer(exifItem: Fixtures.heifExifItem(tiff), inIdat: true)
        XCTAssertEqual(ContainerMetadata.exifTIFF(in: bytes), tiff)
        XCTAssertEqual(ExifReader.read(from: bytes)?.make, "PhoneMaker")
    }

    func testExifItemWithAJPEGStyleMarkerIsFound() {
        let marked = Fixtures.heifContainer(exifItem: Fixtures.heifExifItem(tiff, withMarker: true))
        XCTAssertEqual(ContainerMetadata.exifTIFF(in: marked), tiff)

        // The marker present, but the offset field (wrongly) left at zero.
        let misdeclared = Fixtures.heifContainer(exifItem: Fixtures.bigEndian32(0) + Array("Exif\0\0".utf8) + tiff)
        XCTAssertEqual(ExifReader.read(from: misdeclared)?.make, "PhoneMaker")
    }

    func testMalformedHEIFMetadataReadsAsNoExifWithoutCrashing() {
        let bytes = Fixtures.heifContainer(exifItem: Fixtures.heifExifItem(tiff))
        // The Exif item's extent now runs past the end of the file.
        XCTAssertNil(ExifReader.read(from: Array(bytes.prefix(bytes.count - 10))))
        // Cut off inside the meta box.
        XCTAssertNil(ExifReader.read(from: Array(bytes.prefix(40))))
        // A meta box claiming to be larger than the file.
        var oversized = bytes
        let metaStart = 24
        oversized.replaceSubrange(metaStart..<(metaStart + 4), with: Fixtures.bigEndian32(0x7FFF_FFFF))
        XCTAssertNil(ExifReader.read(from: oversized))
        // An Exif item that isn't TIFF data at all.
        XCTAssertNil(ExifReader.read(from: Fixtures.heifContainer(exifItem: Fixtures.bigEndian32(0) + [UInt8](repeating: 0x41, count: 64))))
        // No meta box.
        XCTAssertNil(ExifReader.read(from: Fixtures.isoBox("ftyp", Array("heic".utf8) + Fixtures.bigEndian32(0) + Array("mif1".utf8))))
    }

    // MARK: - WebP EXIF chunk (no codec library needed)

    private func webp(exif: [UInt8]?) -> [UInt8] {
        // An odd-sized image chunk, so the EXIF chunk sits after padding.
        Fixtures.webpContainer(imageChunk: Fixtures.riffChunk("VP8L", [0x2F, 0, 0, 0, 0]), width: 8, height: 8, exifPayload: exif)
    }

    func testExifChunkIsFound() {
        let bytes = webp(exif: tiff)
        XCTAssertEqual(ImageFormat.detect(from: bytes), .webp)
        XCTAssertEqual(ContainerMetadata.exifTIFF(in: bytes), tiff)
        XCTAssertEqual(ExifReader.read(from: bytes)?.make, "PhoneMaker")
    }

    func testExifChunkWithAJPEGStyleMarkerIsFound() {
        XCTAssertEqual(ContainerMetadata.exifTIFF(in: webp(exif: Array("Exif\0\0".utf8) + tiff)), tiff)
    }

    func testMalformedWebPMetadataReadsAsNoExifWithoutCrashing() {
        XCTAssertNil(ExifReader.read(from: webp(exif: nil)))
        let bytes = webp(exif: tiff)
        XCTAssertNil(ExifReader.read(from: Array(bytes.prefix(bytes.count - 4))), "EXIF chunk cut short")
        XCTAssertNil(ExifReader.read(from: webp(exif: [UInt8](repeating: 0x20, count: 40))), "not TIFF data")
    }

    // MARK: - Metadata analysis

    private func analyze(_ bytes: [UInt8], format: ImageFormat, flagMissingExif: Bool = false) throws -> AnalyzerFinding {
        var config = ForensicLensConfig.default
        config.metadata.flagMissingExif = flagMissingExif
        return try MetadataAnalyzer().analyze(ImageData(rawBytes: bytes, pixels: nil, format: format), config: config)
    }

    func testEditingSoftwareInHEIFExifIsFlagged() throws {
        let edited = Fixtures.cameraExifTIFF(software: "Adobe Photoshop 25.0")
        let finding = try analyze(Fixtures.heifContainer(exifItem: Fixtures.heifExifItem(edited)), format: .heif)
        XCTAssertGreaterThan(finding.score, 0)
        XCTAssertTrue(finding.indicators.contains { $0.message.contains("Adobe Photoshop 25.0") }, "\(finding.indicators)")
    }

    func testEditingSoftwareInWebPExifIsFlagged() throws {
        let finding = try analyze(webp(exif: Fixtures.cameraExifTIFF(software: "GIMP 2.10")), format: .webp)
        XCTAssertGreaterThan(finding.score, 0)
        XCTAssertTrue(finding.indicators.contains { $0.message.contains("GIMP 2.10") }, "\(finding.indicators)")
    }

    func testCleanCameraExifIsConsistent() throws {
        let finding = try analyze(Fixtures.heifContainer(exifItem: Fixtures.heifExifItem(tiff)), format: .heif)
        XCTAssertEqual(finding.score, 0)
        XCTAssertTrue(finding.summary.contains("internally consistent"), finding.summary)
    }

    func testMissingExifInHEIFIsFlaggedLikeJPEGWhenConfigured() throws {
        let noExif = Fixtures.isoBox("ftyp", Array("heic".utf8) + Fixtures.bigEndian32(0) + Array("mif1heic".utf8))
        let flagged = try analyze(noExif, format: .heif, flagMissingExif: true)
        XCTAssertEqual(flagged.score, 20)
        XCTAssertEqual(flagged.summary, "No EXIF metadata found in a HEIF file.")

        let notFlagged = try analyze(noExif, format: .heif)
        XCTAssertEqual(notFlagged.score, 0)
        XCTAssertEqual(notFlagged.summary, "No EXIF metadata found in this HEIF file.")
    }

    func testMissingExifInWebPIsNeverSuspicious() throws {
        let finding = try analyze(webp(exif: nil), format: .webp, flagMissingExif: true)
        XCTAssertEqual(finding.score, 0)
        XCTAssertTrue(finding.summary.contains("WebP"), finding.summary)
    }

    func testThumbnailCheckReadsHEIFAndWebPExif() throws {
        // The EXIF is found (so the check gets as far as looking for IFD1)
        // rather than being turned away as a format without EXIF.
        for (bytes, format) in [(Fixtures.heifContainer(exifItem: Fixtures.heifExifItem(tiff)), ImageFormat.heif), (webp(exif: tiff), .webp)] {
            let finding = try ThumbnailConsistencyAnalyzer().analyze(ImageData(rawBytes: bytes, pixels: nil, format: format), config: .default)
            XCTAssertEqual(finding.score, 0)
            XCTAssertTrue(finding.summary.contains("no embedded EXIF thumbnail"), finding.summary)
        }
    }

    // MARK: - Files written by the real codecs

    func testExifStoredByLibheifIsRead() throws {
        let edited = Fixtures.cameraExifTIFF(make: "PhoneMaker", software: "Snapseed 2.0")
        let bytes = try Fixtures.heifFile(Fixtures.quadrantsBuffer(width: 32, height: 32), quality: 80, exifTIFF: edited)
        let exif = try XCTUnwrap(ExifReader.read(from: bytes))
        XCTAssertEqual(exif.make, "PhoneMaker")
        XCTAssertEqual(exif.software, "Snapseed 2.0")

        let finding = try MetadataAnalyzer().analyze(ImageData.load(bytes), config: .default)
        XCTAssertTrue(finding.indicators.contains { $0.message.contains("Snapseed 2.0") }, "\(finding.indicators)")
    }

    func testExifInARealWebPFileIsRead() throws {
        let bytes = try Fixtures.webpFile(Fixtures.quadrantsBuffer(width: 32, height: 32), exifTIFF: tiff)
        let image = try ImageData.load(bytes)
        XCTAssertNotNil(image.pixels)
        XCTAssertEqual(ExifReader.read(from: image.rawBytes)?.make, "PhoneMaker")
    }
}
