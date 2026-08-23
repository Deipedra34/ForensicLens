import ForensicLens
import ImageDecoding

/// Synthetic test image builders shared across the test suite.
///
/// Every fixture here is generated in-process from a fixed seed. Nothing
/// is loaded from disk, and nothing depends on a real photo existing
/// anywhere. That keeps the whole suite runnable offline, deterministically,
/// with no special privileges, per the project's testing requirements.
enum Fixtures {
    /// A small deterministic pseudo-random generator (a linear congruential
    /// generator). `swift test` needs to be fully reproducible, so tests
    /// use this instead of `Int.random`. A flaky test that only fails on
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

    /// A flat, single-color image with no texture at all: the "nothing to
    /// see here" fixture used to exercise the uniform-image edge case in
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
    /// `(srcX, srcY)` duplicated on top of `(dstX, dstY)`: a synthetic
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

    /// Bytes for a JPEG file with no APP1/Exif segment at all, just SOI
    /// followed immediately by EOI. ForensicLens can't decode this JPEG's
    /// pixels (see `ImageDecoder`), but `ImageFormat.detect` still
    /// recognizes it, which is all `MetadataAnalyzer` needs.
    static func jpegBytesWithNoExif() -> [UInt8] {
        [0xFF, 0xD8, 0xFF, 0xD9]
    }

    /// Bytes for a JPEG file whose APP1 segment carries the given EXIF
    /// fields. Any parameter left `nil` is simply omitted from the file.
    ///
    /// - Parameters:
    ///   - gpsDateTimeUTC: A `"YYYY:MM:DD HH:MM:SS"` string written as the
    ///     combined `GPSDateStamp` + `GPSTimeStamp` pair.
    ///   - gpsAltitude: Written as `GPSAltitude`, encoded as a *signed*
    ///     rational (numerator/1000) even though the real tag type is the
    ///     unsigned RATIONAL -- this is what lets tests construct the
    ///     malformed "negative altitude" fixture `readSignedRational`
    ///     is meant to catch.
    static func jpegBytes(
        make: String? = nil,
        model: String? = nil,
        software: String? = nil,
        lensModel: String? = nil,
        dateTime: String? = nil,
        dateTimeOriginal: String? = nil,
        dateTimeDigitized: String? = nil,
        gpsDateTimeUTC: String? = nil,
        gpsAltitude: Double? = nil,
        gpsAltitudeRef: UInt8? = nil
    ) -> [UInt8] {
        var ifd0Fields: [ExifFixtureBuilder.Field] = []
        if let make { ifd0Fields.append(.init(tag: 0x010F, value: .ascii(make))) }
        if let model { ifd0Fields.append(.init(tag: 0x0110, value: .ascii(model))) }
        if let software { ifd0Fields.append(.init(tag: 0x0131, value: .ascii(software))) }
        if let dateTime { ifd0Fields.append(.init(tag: 0x0132, value: .ascii(dateTime))) }

        var subIFDFields: [ExifFixtureBuilder.Field] = []
        if let dateTimeOriginal { subIFDFields.append(.init(tag: 0x9003, value: .ascii(dateTimeOriginal))) }
        if let dateTimeDigitized { subIFDFields.append(.init(tag: 0x9004, value: .ascii(dateTimeDigitized))) }
        if let lensModel { subIFDFields.append(.init(tag: 0xA434, value: .ascii(lensModel))) }

        var gpsIFDFields: [ExifFixtureBuilder.Field] = []
        if let gpsDateTimeUTC {
            let segments = gpsDateTimeUTC.split(separator: " ")
            precondition(segments.count == 2, "gpsDateTimeUTC must be \"YYYY:MM:DD HH:MM:SS\"")
            let timeParts = segments[1].split(separator: ":").map { Int32($0)! }
            precondition(timeParts.count == 3, "gpsDateTimeUTC must be \"YYYY:MM:DD HH:MM:SS\"")
            gpsIFDFields.append(.init(tag: 0x001D, value: .ascii(String(segments[0]))))
            gpsIFDFields.append(.init(tag: 0x0007, value: .rationalTriplet(timeParts.map { ($0, 1) })))
        }
        if let gpsAltitude {
            gpsIFDFields.append(.init(tag: 0x0006, value: .rational(numerator: Int32((gpsAltitude * 1000).rounded()), denominator: 1000)))
        }
        if let gpsAltitudeRef {
            gpsIFDFields.append(.init(tag: 0x0005, value: .byte(gpsAltitudeRef)))
        }

        let tiff = ExifFixtureBuilder.build(ifd0Fields: ifd0Fields, subIFDFields: subIFDFields, gpsIFDFields: gpsIFDFields)

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
/// exactly (byte order, inline-vs-offset value storage, the Exif SubIFD and
/// GPS IFD pointers) so the tests exercise the real parsing path rather
/// than a simplified stand-in.
enum ExifFixtureBuilder {
    enum FieldValue {
        case ascii(String)
        case byte(UInt8)
        /// A single RATIONAL, written as a signed two's-complement
        /// numerator so fixtures can represent the malformed
        /// "negative GPSAltitude" case `readSignedRational` decodes.
        case rational(numerator: Int32, denominator: UInt32)
        /// Several RATIONALs in one field, e.g. `GPSTimeStamp`'s
        /// hour/minute/second triplet.
        case rationalTriplet([(Int32, UInt32)])
    }

    struct Field {
        let tag: UInt16
        let value: FieldValue
    }

    static func build(ifd0Fields: [Field], subIFDFields: [Field], gpsIFDFields: [Field] = []) -> [UInt8] {
        let hasSubIFD = !subIFDFields.isEmpty
        let hasGPSIFD = !gpsIFDFields.isEmpty

        var entryCountIFD0 = ifd0Fields.count
        if hasSubIFD { entryCountIFD0 += 1 }
        if hasGPSIFD { entryCountIFD0 += 1 }

        let ifd0Start = 8
        let ifd0Size = 2 + entryCountIFD0 * 12 + 4
        let subIFDStart = ifd0Start + ifd0Size
        let subIFDSize = hasSubIFD ? (2 + subIFDFields.count * 12 + 4) : 0
        let gpsIFDStart = subIFDStart + subIFDSize
        let gpsIFDSize = hasGPSIFD ? (2 + gpsIFDFields.count * 12 + 4) : 0
        let externalStart = gpsIFDStart + gpsIFDSize

        var external: [UInt8] = []

        func valueBytes(for value: FieldValue) -> (inline: [UInt8]?, offset: UInt32?, count: UInt32, type: UInt16) {
            switch value {
            case .ascii(let text):
                var raw = Array(text.utf8)
                raw.append(0)
                let count = UInt32(raw.count)
                if raw.count <= 4 {
                    while raw.count < 4 { raw.append(0) }
                    return (raw, nil, count, 2)
                } else {
                    let offset = UInt32(externalStart + external.count)
                    external.append(contentsOf: raw)
                    return (nil, offset, count, 2)
                }
            case .byte(let b):
                return ([b, 0, 0, 0], nil, 1, 1)
            case .rational(let numerator, let denominator):
                let offset = UInt32(externalStart + external.count)
                external.append(contentsOf: u32le(UInt32(bitPattern: numerator)))
                external.append(contentsOf: u32le(denominator))
                return (nil, offset, 1, 5)
            case .rationalTriplet(let triplet):
                let offset = UInt32(externalStart + external.count)
                for (numerator, denominator) in triplet {
                    external.append(contentsOf: u32le(UInt32(bitPattern: numerator)))
                    external.append(contentsOf: u32le(denominator))
                }
                return (nil, offset, UInt32(triplet.count), 5)
            }
        }

        func writeEntries(_ fields: [Field], extraPointers: [(tag: UInt16, offset: UInt32)]) -> [UInt8] {
            var bytes: [UInt8] = []
            bytes.append(contentsOf: u16le(UInt16(fields.count + extraPointers.count)))
            for field in fields {
                let (inline, offset, valueCount, type) = valueBytes(for: field.value)
                bytes.append(contentsOf: u16le(field.tag))
                bytes.append(contentsOf: u16le(type))
                bytes.append(contentsOf: u32le(valueCount))
                if let inline {
                    bytes.append(contentsOf: inline)
                } else if let offset {
                    bytes.append(contentsOf: u32le(offset))
                }
            }
            for pointer in extraPointers {
                bytes.append(contentsOf: u16le(pointer.tag))
                bytes.append(contentsOf: u16le(4)) // LONG
                bytes.append(contentsOf: u32le(1))
                bytes.append(contentsOf: u32le(pointer.offset))
            }
            bytes.append(contentsOf: u32le(0)) // next IFD offset
            return bytes
        }

        var extraPointers: [(tag: UInt16, offset: UInt32)] = []
        if hasSubIFD { extraPointers.append((0x8769, UInt32(subIFDStart))) }
        if hasGPSIFD { extraPointers.append((0x8825, UInt32(gpsIFDStart))) }

        let ifd0Bytes = writeEntries(ifd0Fields, extraPointers: extraPointers)
        let subIFDBytes = hasSubIFD ? writeEntries(subIFDFields, extraPointers: []) : []
        let gpsIFDBytes = hasGPSIFD ? writeEntries(gpsIFDFields, extraPointers: []) : []

        var result: [UInt8] = []
        result.append(contentsOf: Array("II".utf8))
        result.append(contentsOf: u16le(0x002A))
        result.append(contentsOf: u32le(UInt32(ifd0Start)))
        result.append(contentsOf: ifd0Bytes)
        result.append(contentsOf: subIFDBytes)
        result.append(contentsOf: gpsIFDBytes)
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
