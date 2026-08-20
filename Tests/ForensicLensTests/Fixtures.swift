import ForensicLens
import ImageDecoding

/// Synthetic test image builders shared across the test suite.
///
/// Every fixture here is generated in-process from a fixed seed -- nothing
/// is loaded from disk, and nothing depends on a real photo existing
/// anywhere. That keeps the whole suite runnable offline, deterministically,
/// with no special privileges, per the project's testing requirements.
enum Fixtures {
    /// A small deterministic pseudo-random generator (a linear congruential
    /// generator). `swift test` must be fully reproducible, so tests use
    /// this instead of `Int.random` -- a flaky test that only fails on
    /// certain random draws is worse than no test at all.
    struct SeededGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
        mutating func nextByte() -> UInt8 {
            UInt8(truncatingIfNeeded: next() >> 24)
        }
    }

    /// A flat, single-color image with no texture at all -- the "nothing
    /// to see here" fixture used to exercise the uniform-image edge case in
    /// clone detection and the "no anomalies" path in ELA.
    static func uniformBuffer(width: Int, height: Int, channels: Int = 3, value: UInt8 = 128) throws -> PixelBuffer {
        try PixelBuffer(width: width, height: height, channels: channels, pixels: [UInt8](repeating: value, count: width * height * channels))
    }

    /// A pseudo-random noise image. High-frequency, high-variance content
    /// like this is what both ELA (which responds to high-frequency detail)
    /// and clone detection (which needs non-flat blocks to fingerprint)
    /// need in order to have anything meaningful to measure.
    static func noiseBuffer(width: Int, height: Int, channels: Int = 3, seed: UInt64 = 1) throws -> PixelBuffer {
        var generator = SeededGenerator(seed: seed)
        var pixels = [UInt8](repeating: 0, count: width * height * channels)
        for i in 0..<pixels.count {
            pixels[i] = generator.nextByte()
        }
        return try PixelBuffer(width: width, height: height, channels: channels, pixels: pixels)
    }

    /// Returns a copy of `buffer` with the `size` x `size` patch at
    /// `(srcX, srcY)` duplicated on top of `(dstX, dstY)` -- a synthetic
    /// copy-move forgery, used to give `CloneDetectionAnalyzer` a
    /// guaranteed, exact match to find.
    static func pastingPatch(of size: Int, from src: (x: Int, y: Int), to dst: (x: Int, y: Int), into buffer: PixelBuffer) throws -> PixelBuffer {
        var pixels = buffer.pixels
        for row in 0..<size {
            for col in 0..<size {
                let srcOffset = buffer.offset(x: src.x + col, y: src.y + row)
                let dstOffset = buffer.offset(x: dst.x + col, y: dst.y + row)
                for c in 0..<buffer.channels {
                    pixels[dstOffset + c] = buffer.pixels[srcOffset + c]
                }
            }
        }
        return try PixelBuffer(width: buffer.width, height: buffer.height, channels: buffer.channels, pixels: pixels)
    }

    /// Returns a copy of `buffer` with a `size` x `size` block of noise
    /// stamped at `(x, y)`, used to give ELA an isolated region of
    /// high-frequency content against an otherwise flat background.
    static func stampingNoisePatch(of size: Int, at position: (x: Int, y: Int), into buffer: PixelBuffer, seed: UInt64 = 7) throws -> PixelBuffer {
        var pixels = buffer.pixels
        var generator = SeededGenerator(seed: seed)
        for row in 0..<size {
            for col in 0..<size {
                let offset = buffer.offset(x: position.x + col, y: position.y + row)
                for c in 0..<buffer.channels {
                    pixels[offset + c] = generator.nextByte()
                }
            }
        }
        return try PixelBuffer(width: buffer.width, height: buffer.height, channels: buffer.channels, pixels: pixels)
    }

    /// Wraps a `PixelBuffer` as an `ImageData` by round-tripping it through
    /// the PPM encoder/decoder, exercising the same decode path a real file
    /// on disk would go through rather than hand-assembling `ImageData`.
    static func imageData(from buffer: PixelBuffer) throws -> ImageData {
        let bytes = ImageEncoder.encodePPM(buffer)
        return try ImageData.load(bytes)
    }

    // MARK: - Synthetic JPEG / EXIF fixtures

    /// Bytes for a JPEG file with no APP1/Exif segment at all -- just SOI
    /// followed immediately by EOI. ForensicLens can't decode this JPEG's
    /// pixels (see `ImageDecoder`), but `ImageFormat.detect` still
    /// recognizes it, which is all `MetadataAnalyzer` needs.
    static func jpegBytesWithNoExif() -> [UInt8] {
        [0xFF, 0xD8, 0xFF, 0xD9]
    }

    /// Bytes for a JPEG file whose APP1 segment carries the given EXIF
    /// fields. Any parameter left `nil` is simply omitted from the file.
    static func jpegBytes(
        make: String? = nil,
        model: String? = nil,
        software: String? = nil,
        dateTime: String? = nil,
        dateTimeOriginal: String? = nil,
        dateTimeDigitized: String? = nil
    ) -> [UInt8] {
        var ifd0Fields: [ExifFixtureBuilder.Field] = []
        if let make { ifd0Fields.append(.init(tag: 0x010F, text: make)) }
        if let model { ifd0Fields.append(.init(tag: 0x0110, text: model)) }
        if let software { ifd0Fields.append(.init(tag: 0x0131, text: software)) }
        if let dateTime { ifd0Fields.append(.init(tag: 0x0132, text: dateTime)) }

        var subIFDFields: [ExifFixtureBuilder.Field] = []
        if let dateTimeOriginal { subIFDFields.append(.init(tag: 0x9003, text: dateTimeOriginal)) }
        if let dateTimeDigitized { subIFDFields.append(.init(tag: 0x9004, text: dateTimeDigitized)) }

        let tiff = ExifFixtureBuilder.build(ifd0Fields: ifd0Fields, subIFDFields: subIFDFields)

        var app1Payload = Array("Exif\0\0".utf8)
        app1Payload.append(contentsOf: tiff)
        let segmentLength = UInt16(app1Payload.count + 2)

        var bytes: [UInt8] = [0xFF, 0xD8] // SOI
        bytes.append(0xFF)
        bytes.append(0xE1) // APP1
        bytes.append(UInt8((segmentLength >> 8) & 0xFF))
        bytes.append(UInt8(segmentLength & 0xFF))
        bytes.append(contentsOf: app1Payload)
        bytes.append(0xFF)
        bytes.append(0xD9) // EOI
        return bytes
    }
}

/// Hand-rolled TIFF writer used only to build EXIF fixtures for
/// `MetadataAnalyzerTests`. It mirrors `ExifReader`'s layout expectations
/// exactly (byte order, inline-vs-offset ASCII storage, the Exif SubIFD
/// pointer) so the tests exercise the real parsing path rather than a
/// simplified stand-in.
enum ExifFixtureBuilder {
    struct Field {
        let tag: UInt16
        let text: String
    }

    static func build(ifd0Fields: [Field], subIFDFields: [Field]) -> [UInt8] {
        let hasSubIFD = !subIFDFields.isEmpty
        var entryCountIFD0 = ifd0Fields.count
        if hasSubIFD { entryCountIFD0 += 1 }

        let ifd0Start = 8
        let ifd0Size = 2 + entryCountIFD0 * 12 + 4
        let subIFDStart = ifd0Start + ifd0Size
        let subIFDSize = hasSubIFD ? (2 + subIFDFields.count * 12 + 4) : 0
        let externalStart = subIFDStart + subIFDSize

        var external: [UInt8] = []

        func valueBytes(for text: String) -> (inline: [UInt8]?, offset: UInt32?, count: UInt32) {
            var raw = Array(text.utf8)
            raw.append(0)
            let count = UInt32(raw.count)
            if raw.count <= 4 {
                while raw.count < 4 { raw.append(0) }
                return (raw, nil, count)
            } else {
                let offset = UInt32(externalStart + external.count)
                external.append(contentsOf: raw)
                return (nil, offset, count)
            }
        }

        func writeEntries(_ fields: [Field], extraPointer: (tag: UInt16, offset: UInt32)?) -> [UInt8] {
            var bytes: [UInt8] = []
            var count = fields.count
            if extraPointer != nil { count += 1 }
            bytes.append(contentsOf: u16le(UInt16(count)))
            for field in fields {
                let (inline, offset, textCount) = valueBytes(for: field.text)
                bytes.append(contentsOf: u16le(field.tag))
                bytes.append(contentsOf: u16le(2)) // ASCII
                bytes.append(contentsOf: u32le(textCount))
                if let inline {
                    bytes.append(contentsOf: inline)
                } else if let offset {
                    bytes.append(contentsOf: u32le(offset))
                }
            }
            if let extraPointer {
                bytes.append(contentsOf: u16le(extraPointer.tag))
                bytes.append(contentsOf: u16le(4)) // LONG
                bytes.append(contentsOf: u32le(1))
                bytes.append(contentsOf: u32le(extraPointer.offset))
            }
            bytes.append(contentsOf: u32le(0)) // next IFD offset
            return bytes
        }

        let ifd0Bytes = writeEntries(ifd0Fields, extraPointer: hasSubIFD ? (tag: 0x8769, offset: UInt32(subIFDStart)) : nil)
        let subIFDBytes = hasSubIFD ? writeEntries(subIFDFields, extraPointer: nil) : []

        var result: [UInt8] = []
        result.append(contentsOf: Array("II".utf8))
        result.append(contentsOf: u16le(0x002A))
        result.append(contentsOf: u32le(UInt32(ifd0Start)))
        result.append(contentsOf: ifd0Bytes)
        result.append(contentsOf: subIFDBytes)
        result.append(contentsOf: external)
        return result
    }

    private static func u16le(_ value: UInt16) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]
    }

    private static func u32le(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)]
    }
}
