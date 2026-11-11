import Foundation
import XCTest
import ImageDecoding

/// The skip-or-fail rule for tests that need libheif or libwebp.
///
/// Those libraries are loaded at run time and aren't needed to build, so a
/// contributor without them can still run the suite: their tests are
/// skipped, with the install command in the skip message. CI sets
/// `FORENSICLENS_REQUIRE_IMAGE_CODECS=1` after installing them, which turns
/// a missing library into a failure instead, so the HEIF/WebP tests can't
/// silently stop running there.
enum CodecTestSupport {
    static var librariesRequired: Bool {
        ProcessInfo.processInfo.environment["FORENSICLENS_REQUIRE_IMAGE_CODECS"] == "1"
    }

    static func require(_ library: CodecLibrary, file: StaticString = #filePath, line: UInt = #line) throws {
        guard case .unavailable(let reason) = library.status else { return }
        if librariesRequired {
            XCTFail("\(library.rawValue) must be available when FORENSICLENS_REQUIRE_IMAGE_CODECS=1: \(reason)", file: file, line: line)
        }
        throw XCTSkip("\(library.rawValue) isn't installed (\(reason)). \(library.installHint)")
    }
}

/// Synthetic HEIF/HEIC and WebP files, built in-process like every other
/// fixture: real files written by libheif/libwebp from known pixels, and
/// hand-assembled containers for the metadata tests that don't need any
/// codec at all.
extension Fixtures {
    /// The four quadrant colors of `quadrantsBuffer`: top left, top right,
    /// bottom left, bottom right.
    static let quadrantColors: [[UInt8]] = [[220, 40, 40], [40, 200, 60], [50, 60, 210], [128, 128, 128]]

    /// Four flat RGB quadrants in `quadrantColors`.
    static func quadrantsBuffer(width: Int, height: Int) throws -> PixelBuffer {
        var pixels: [UInt8] = []
        pixels.reserveCapacity(width * height * 3)
        for y in 0..<height {
            for x in 0..<width {
                let index = (y < height / 2 ? 0 : 2) + (x < width / 2 ? 0 : 1)
                pixels.append(contentsOf: quadrantColors[index])
            }
        }
        return try PixelBuffer(width: width, height: height, channels: 3, pixels: pixels)
    }

    /// A WebP file of `buffer`, written by libwebp: lossless when `quality`
    /// is `nil`. With `exifTIFF`, the file uses WebP's extended format and
    /// carries that block in an `EXIF` chunk. Skips the calling test if
    /// libwebp isn't installed.
    static func webpFile(_ buffer: PixelBuffer, quality: Int? = nil, exifTIFF: [UInt8]? = nil, file: StaticString = #filePath, line: UInt = #line) throws -> [UInt8] {
        try CodecTestSupport.require(.libwebp, file: file, line: line)
        let simple = try ImageEncoder.encodeWebP(buffer, quality: quality)
        guard let exifTIFF else { return simple }
        // libwebp's simple encoder writes "RIFF" <size> "WEBP" and one image chunk.
        return webpContainer(imageChunk: Array(simple.dropFirst(12)), width: buffer.width, height: buffer.height, exifPayload: exifTIFF)
    }

    /// An extended-format WebP container: a `VP8X` header chunk, the given
    /// image chunk(s), then an `EXIF` chunk if `exifPayload` is set.
    static func webpContainer(imageChunk: [UInt8], width: Int, height: Int, exifPayload: [UInt8]?, animated: Bool = false) -> [UInt8] {
        var flags: UInt8 = 0
        if exifPayload != nil { flags |= 0x08 }
        if animated { flags |= 0x02 }
        let header = riffChunk("VP8X", [flags, 0, 0, 0] + littleEndian24(width - 1) + littleEndian24(height - 1))
        var body = Array("WEBP".utf8) + header + imageChunk
        if let exifPayload {
            body += riffChunk("EXIF", exifPayload)
        }
        return Array("RIFF".utf8) + littleEndian32(body.count) + body
    }

    /// A RIFF chunk: type, little-endian size, payload, padding to an even length.
    static func riffChunk(_ type: String, _ payload: [UInt8]) -> [UInt8] {
        Array(type.utf8) + littleEndian32(payload.count) + payload + (payload.count % 2 == 1 ? [0] : [])
    }

    /// An HEIC file of `buffer`, written by libheif: lossless (as close as
    /// HEVC's YCbCr coding allows) when `quality` is `nil`. `exifTIFF` is
    /// stored as the image's Exif item. Skips the calling test if libheif,
    /// or its HEVC encoder, isn't installed.
    static func heifFile(_ buffer: PixelBuffer, quality: Int? = nil, exifTIFF: [UInt8]? = nil, file: StaticString = #filePath, line: UInt = #line) throws -> [UInt8] {
        try CodecTestSupport.require(.libheif, file: file, line: line)
        do {
            return try ImageEncoder.encodeHEIF(buffer, quality: quality, exif: exifTIFF)
        } catch ImageEncodingError.encoderUnavailable(let reason) {
            if CodecTestSupport.librariesRequired {
                XCTFail("libheif can't encode HEIC, but FORENSICLENS_REQUIRE_IMAGE_CODECS=1: \(reason)", file: file, line: line)
            }
            throw XCTSkip("libheif has no HEVC encoder here (\(reason)).")
        }
    }

    /// A HEIF file with no image data at all: `ftyp` and a `meta` box whose
    /// one item is an Exif block, stored in an `mdat` box (construction
    /// method 0) or inside `meta` in an `idat` box (method 1). Enough for
    /// metadata parsing, which never decodes pixels.
    static func heifContainer(exifItem: [UInt8], inIdat: Bool = false) -> [UInt8] {
        let ftyp = isoBox("ftyp", Array("heic".utf8) + bigEndian32(0) + Array("mif1heic".utf8))
        let infe = isoFullBox("infe", version: 2, bigEndian16(1) + bigEndian16(0) + Array("Exif".utf8) + [0])
        let iinf = isoFullBox("iinf", version: 0, bigEndian16(1) + infe)
        func iloc(offset: Int) -> [UInt8] {
            // Version 1: 4-byte offsets and lengths, no base offset, no index.
            isoFullBox("iloc", version: 1, [0x44, 0x00] + bigEndian16(1)
                + bigEndian16(1) + bigEndian16(inIdat ? 1 : 0) + bigEndian16(0)
                + bigEndian16(1) + bigEndian32(offset) + bigEndian32(exifItem.count))
        }
        let idat = inIdat ? isoBox("idat", exifItem) : []
        // The meta box's size doesn't depend on the offset written into iloc.
        let metaSize = 12 + iinf.count + iloc(offset: 0).count + idat.count
        let itemOffset = inIdat ? 0 : ftyp.count + metaSize + 8
        let meta = isoFullBox("meta", version: 0, iinf + iloc(offset: itemOffset) + idat)
        let mdat = inIdat ? [] : isoBox("mdat", exifItem)
        return ftyp + meta + mdat
    }

    /// A HEIF `Exif` item: the 4-byte offset to the TIFF header, then
    /// `tiff`, optionally behind a JPEG-style `"Exif\0\0"` marker.
    static func heifExifItem(_ tiff: [UInt8], withMarker: Bool = false) -> [UInt8] {
        withMarker ? bigEndian32(6) + Array("Exif\0\0".utf8) + tiff : bigEndian32(0) + tiff
    }

    /// An EXIF (TIFF) block with a camera Make and Model and, if given, a
    /// Software tag.
    static func cameraExifTIFF(make: String = "TestCam", software: String? = nil) -> [UInt8] {
        var fields = [
            ExifFixtureBuilder.Field(tag: 0x010F, value: .ascii(make)),
            ExifFixtureBuilder.Field(tag: 0x0110, value: .ascii("Model X")),
        ]
        if let software {
            fields.append(ExifFixtureBuilder.Field(tag: 0x0131, value: .ascii(software)))
        }
        return ExifFixtureBuilder.build(ifd0Fields: fields, subIFDFields: [])
    }

    static func isoBox(_ type: String, _ content: [UInt8]) -> [UInt8] {
        bigEndian32(8 + content.count) + Array(type.utf8) + content
    }

    static func isoFullBox(_ type: String, version: UInt8, _ content: [UInt8]) -> [UInt8] {
        isoBox(type, [version, 0, 0, 0] + content)
    }

    static func bigEndian16(_ value: Int) -> [UInt8] {
        [UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    static func bigEndian32(_ value: Int) -> [UInt8] {
        [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    static func littleEndian24(_ value: Int) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF)]
    }

    static func littleEndian32(_ value: Int) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)]
    }
}
