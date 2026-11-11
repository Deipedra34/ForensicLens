/// Finds the `EXIF` chunk of a WebP file.
///
/// A WebP file is a RIFF container: `"RIFF"`, a little-endian size, `"WEBP"`,
/// then chunks of `<four-character type> <little-endian size> <payload>`,
/// each padded to an even length. EXIF metadata lives in an `EXIF` chunk of
/// the extended format (after a `VP8X` header chunk).
enum WebPExifLocator {
    /// The payload of the first `EXIF` chunk, or `nil`.
    static func exifPayload(in data: [UInt8]) -> [UInt8]? {
        guard data.count >= 12 else { return nil }
        let riffSize = Int(littleEndianU32(data, at: 4))
        // The RIFF size counts everything after its own field.
        let end = min(data.count, riffSize <= Int.max - 8 ? riffSize + 8 : data.count)
        var position = 12
        while position + 8 <= end {
            let type = String(decoding: data[position..<(position + 4)], as: UTF8.self)
            let size = Int(littleEndianU32(data, at: position + 4))
            let payloadStart = position + 8
            guard size <= end - payloadStart else { return nil }
            if type == "EXIF" {
                guard size > 0, size <= ContainerMetadata.maximumExifSize else { return nil }
                return Array(data[payloadStart..<(payloadStart + size)])
            }
            position = payloadStart + size + (size & 1)
        }
        return nil
    }

    private static func littleEndianU32(_ data: [UInt8], at offset: Int) -> UInt32 {
        UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
    }
}
