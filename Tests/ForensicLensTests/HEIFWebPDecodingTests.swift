import XCTest
import ImageDecoding

/// Decoding HEIF/HEIC and WebP: format detection from the file's own bytes,
/// real files written by libheif/libwebp from known pixels decoding back to
/// those pixels (exactly, for lossless WebP), and malformed files failing
/// with a clear `ImageDecodingError` instead of crashing.
final class HEIFWebPDecodingTests: XCTestCase {
    // MARK: - Format detection (no codec library needed)

    private func ftyp(major: String, compatible: [String]) -> [UInt8] {
        Fixtures.isoBox("ftyp", Array(major.utf8) + Fixtures.bigEndian32(0) + compatible.flatMap { Array($0.utf8) })
            + Fixtures.isoBox("mdat", [0, 0, 0, 0])
    }

    func testHEIFIsRecognizedByItsBrands() {
        XCTAssertEqual(ImageFormat.detect(from: ftyp(major: "heic", compatible: ["mif1", "heic"])), .heif)
        XCTAssertEqual(ImageFormat.detect(from: ftyp(major: "mif1", compatible: ["heic"])), .heif)
        XCTAssertEqual(ImageFormat.detect(from: ftyp(major: "heix", compatible: [])), .heif)
        XCTAssertEqual(ImageFormat.detect(from: ftyp(major: "mif1", compatible: ["miaf"])), .heif, "generic HEIF")
    }

    func testOtherISOMediaFilesAreNotHEIF() {
        XCTAssertNil(ImageFormat.detect(from: ftyp(major: "avif", compatible: ["mif1", "miaf"])), "AVIF isn't claimed")
        XCTAssertNil(ImageFormat.detect(from: ftyp(major: "isom", compatible: ["mp41", "iso2"])), "MP4 video")
        XCTAssertNil(ImageFormat.detect(from: Array(ftyp(major: "heic", compatible: ["mif1"]).prefix(12))), "truncated")
    }

    func testWebPIsRecognizedByItsRIFFHeader() {
        let webp = Array("RIFF".utf8) + Fixtures.littleEndian32(12) + Array("WEBPVP8L".utf8) + [0, 0, 0, 0]
        XCTAssertEqual(ImageFormat.detect(from: webp), .webp)
        let wave = Array("RIFF".utf8) + Fixtures.littleEndian32(12) + Array("WAVEfmt ".utf8) + [0, 0, 0, 0]
        XCTAssertNil(ImageFormat.detect(from: wave))
    }

    func testFormatNamesExtensionsAndEXIFSupport() {
        XCTAssertEqual(ImageFormat.heif.fileExtensions, ["heic", "heif", "hif"])
        XCTAssertEqual(ImageFormat.webp.fileExtensions, ["webp"])
        XCTAssertEqual(ImageFormat.heif.displayName, "HEIF")
        XCTAssertEqual(ImageFormat.webp.displayName, "WebP")
        XCTAssertTrue(ImageFormat.heif.canCarryEXIF)
        XCTAssertTrue(ImageFormat.webp.canCarryEXIF)
        XCTAssertFalse(ImageFormat.bmp.canCarryEXIF)
    }

    func testAnimatedWebPIsRejectedWithAClearError() {
        let animated = Fixtures.webpContainer(imageChunk: Fixtures.riffChunk("ANIM", [0, 0, 0, 0, 0, 0]), width: 8, height: 8, exifPayload: nil, animated: true)
        XCTAssertEqual(ImageFormat.detect(from: animated), .webp)
        XCTAssertThrowsError(try ImageData.load(animated)) { error in
            guard case .unsupportedFormat(let detail)? = error as? ImageDecodingError else {
                return XCTFail("expected unsupportedFormat, got \(error)")
            }
            XCTAssertTrue(detail.contains("animated"), detail)
        }
    }

    // MARK: - WebP

    func testLosslessWebPRoundTripsExactly() throws {
        let buffer = try Fixtures.noiseBuffer(width: 37, height: 23, seed: 9)
        let bytes = try Fixtures.webpFile(buffer)
        XCTAssertEqual(ImageFormat.detect(from: bytes), .webp)

        let image = try ImageData.load(bytes)
        XCTAssertEqual(image.format, .webp)
        let pixels = try XCTUnwrap(image.pixels)
        XCTAssertEqual(pixels.width, 37)
        XCTAssertEqual(pixels.height, 23)
        XCTAssertEqual(pixels.channels, 3)
        XCTAssertEqual(pixels.pixels, buffer.pixels)
    }

    func testLossyWebPKeepsDimensionsAndColors() throws {
        let buffer = try Fixtures.quadrantsBuffer(width: 64, height: 48)
        let decoded = try ImageDecoder.decode(Fixtures.webpFile(buffer, quality: 90))
        XCTAssertEqual(decoded.width, 64)
        XCTAssertEqual(decoded.height, 48)
        assertQuadrantColors(decoded, tolerance: 12)
    }

    func testGrayscaleWebPDecodesAsRGB() throws {
        let gray = try Fixtures.thumbnailScene(width: 32, height: 24)
        let decoded = try ImageDecoder.decode(Fixtures.webpFile(gray))
        XCTAssertEqual(decoded.channels, 3)
        for (index, value) in gray.pixels.enumerated() {
            let base = index * 3
            XCTAssertEqual([decoded.pixels[base], decoded.pixels[base + 1], decoded.pixels[base + 2]], [value, value, value])
        }
    }

    func testExtendedWebPWithAnExifChunkDecodesTheSamePixels() throws {
        let buffer = try Fixtures.noiseBuffer(width: 20, height: 12, seed: 4)
        let bytes = try Fixtures.webpFile(buffer, exifTIFF: Fixtures.cameraExifTIFF())
        XCTAssertEqual(Array(bytes[12..<16]), Array("VP8X".utf8))
        XCTAssertEqual(try ImageDecoder.decode(bytes).pixels, buffer.pixels)
    }

    func testCorruptWebPThrowsADecodeErrorInsteadOfCrashing() throws {
        let bytes = try Fixtures.webpFile(Fixtures.noiseBuffer(width: 32, height: 32, seed: 2))

        var garbage = bytes
        var generator = Fixtures.SeededGenerator(seed: 5)
        for index in 20..<garbage.count {
            garbage[index] = generator.nextByte()
        }
        let headerOnly = Array("RIFF".utf8) + Fixtures.littleEndian32(4) + Array("WEBP".utf8)

        for (name, data) in [("truncated", Array(bytes.prefix(bytes.count / 2))), ("garbage", garbage), ("header only", headerOnly)] {
            XCTAssertThrowsError(try ImageData.load(data), name) { error in
                guard case .corruptData(let detail)? = error as? ImageDecodingError else {
                    return XCTFail("\(name): expected corruptData, got \(error)")
                }
                XCTAssertTrue(detail.hasPrefix("WebP:"), detail)
            }
        }
    }

    // MARK: - HEIF/HEIC

    func testHEIFDecodesToTheEncodedImage() throws {
        let buffer = try Fixtures.quadrantsBuffer(width: 64, height: 48)
        let bytes = try Fixtures.heifFile(buffer, quality: 90)
        XCTAssertEqual(ImageFormat.detect(from: bytes), .heif)

        let image = try ImageData.load(bytes)
        XCTAssertEqual(image.format, .heif)
        let pixels = try XCTUnwrap(image.pixels)
        XCTAssertEqual(pixels.width, 64)
        XCTAssertEqual(pixels.height, 48)
        XCTAssertEqual(pixels.channels, 3)
        assertQuadrantColors(pixels, tolerance: 16)
    }

    func testLosslessHEIFStaysWithinRoundingOfTheOriginal() throws {
        // Gray content: HEVC codes YCbCr, and gray has no chroma to lose to
        // subsampling, so only the color conversion's rounding remains.
        let gray = try Fixtures.thumbnailScene(width: 64, height: 48)
        let decoded = try ImageDecoder.decode(Fixtures.heifFile(gray))
        XCTAssertEqual(decoded.width, 64)
        XCTAssertEqual(decoded.height, 48)

        var largest = 0
        for (index, value) in gray.pixels.enumerated() {
            for channel in 0..<3 {
                largest = max(largest, abs(Int(decoded.pixels[index * 3 + channel]) - Int(value)))
            }
        }
        XCTAssertLessThanOrEqual(largest, 3)
    }

    func testCorruptHEIFThrowsADecodeErrorInsteadOfCrashing() throws {
        let bytes = try Fixtures.heifFile(Fixtures.quadrantsBuffer(width: 64, height: 48), quality: 80)

        for (name, data) in [("truncated", Array(bytes.prefix(bytes.count / 2))), ("ftyp only", Array(bytes.prefix(40)))] {
            XCTAssertEqual(ImageFormat.detect(from: data), .heif, name)
            XCTAssertThrowsError(try ImageData.load(data), name) { error in
                guard case .corruptData(let detail)? = error as? ImageDecodingError else {
                    return XCTFail("\(name): expected corruptData, got \(error)")
                }
                XCTAssertTrue(detail.hasPrefix("HEIF/HEIC:"), detail)
            }
        }

        // A damaged HEVC bitstream may be concealed rather than rejected;
        // either way, it must not crash.
        var damaged = bytes
        var generator = Fixtures.SeededGenerator(seed: 8)
        for index in (bytes.count * 3 / 4)..<bytes.count {
            damaged[index] = generator.nextByte()
        }
        _ = try? ImageData.load(damaged)
    }

    // MARK: - Library status

    func testLoadedLibrariesDescribeThemselves() throws {
        for library in CodecLibrary.allCases {
            try CodecTestSupport.require(library)
            guard case .available(let description) = library.status else { return XCTFail("\(library) unavailable") }
            XCTAssertTrue(description.hasPrefix(library.rawValue), description)
            XCTAssertTrue(library.isAvailable)
        }
    }

    // MARK: - Helpers

    private func assertQuadrantColors(_ buffer: PixelBuffer, tolerance: Int, file: StaticString = #filePath, line: UInt = #line) {
        let centers = [(buffer.width / 4, buffer.height / 4), (buffer.width * 3 / 4, buffer.height / 4),
                       (buffer.width / 4, buffer.height * 3 / 4), (buffer.width * 3 / 4, buffer.height * 3 / 4)]
        for (quadrant, (x, y)) in centers.enumerated() {
            let base = buffer.offset(x: x, y: y)
            let actual = (0..<3).map { Int(buffer.pixels[base + $0]) }
            let expected = Fixtures.quadrantColors[quadrant].map(Int.init)
            for channel in 0..<3 {
                XCTAssertLessThanOrEqual(abs(actual[channel] - expected[channel]), tolerance,
                                         "quadrant \(quadrant) at (\(x),\(y)): \(actual) vs \(expected)", file: file, line: line)
            }
        }
    }
}
