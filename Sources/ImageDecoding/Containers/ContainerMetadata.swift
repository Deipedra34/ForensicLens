/// Finds the EXIF block in container formats that don't keep it in a JPEG
/// `APP1` segment.
///
/// This only *locates* the bytes; parsing them is left to the EXIF reader
/// that already handles JPEG files (`ExifReader` in the ForensicLens
/// module), so every format goes through one EXIF implementation. The
/// returned block starts at the TIFF header (`"II*\0"` or `"MM\0*"`), with
/// any container-specific prefix removed, so TIFF offsets inside it -- for
/// example IFD1's pointer to the embedded thumbnail -- are relative to its
/// first byte.
///
/// Pure Swift, with no codec library involved: EXIF metadata of a HEIF or
/// WebP file can be read even where libheif/libwebp aren't installed.
public enum ContainerMetadata {
    /// Largest EXIF block accepted, so a corrupt length field can't trigger
    /// an enormous allocation.
    static let maximumExifSize = 16 * 1024 * 1024

    /// The EXIF data embedded in `data`, a complete HEIF or WebP file, or
    /// `nil` if it has none, it's malformed, or `data` is another format.
    public static func exifTIFF(in data: [UInt8]) -> [UInt8]? {
        switch ImageFormat.detect(from: data) {
        case .heif?:
            return HEIFExifLocator.exifPayload(in: data).flatMap(tiffBlock(inHEIFPayload:))
        case .webp?:
            return WebPExifLocator.exifPayload(in: data).flatMap(tiffBlock(inWebPPayload:))
        default:
            return nil
        }
    }

    /// A HEIF `Exif` item starts with a 4-byte big-endian offset from the
    /// end of that field to the TIFF header (normally 0, or 6 when an
    /// `"Exif\0\0"` marker precedes it).
    static func tiffBlock(inHEIFPayload payload: [UInt8]) -> [UInt8]? {
        guard payload.count >= 4 else { return nil }
        let offset = Int(payload[0]) << 24 | Int(payload[1]) << 16 | Int(payload[2]) << 8 | Int(payload[3])
        if offset <= payload.count - 4, startsWithTIFFHeader(payload, at: 4 + offset) {
            return Array(payload[(4 + offset)...])
        }
        // Some writers get the offset field wrong; the header is still near the start.
        return tiffBlock(searching: payload, within: 64)
    }

    /// A WebP `EXIF` chunk holds the TIFF data directly, though some
    /// writers add the JPEG-style `"Exif\0\0"` marker in front.
    static func tiffBlock(inWebPPayload payload: [UInt8]) -> [UInt8]? {
        if startsWithTIFFHeader(payload, at: 0) {
            return payload
        }
        return tiffBlock(searching: payload, within: 16)
    }

    private static func tiffBlock(searching payload: [UInt8], within limit: Int) -> [UInt8]? {
        var offset = 0
        while offset <= min(limit, payload.count - 8) {
            if startsWithTIFFHeader(payload, at: offset) {
                return Array(payload[offset...])
            }
            offset += 1
        }
        return nil
    }

    static func startsWithTIFFHeader(_ bytes: [UInt8], at offset: Int) -> Bool {
        guard offset >= 0, offset + 8 <= bytes.count else { return false }
        let a = bytes[offset], b = bytes[offset + 1], c = bytes[offset + 2], d = bytes[offset + 3]
        return (a == 0x49 && b == 0x49 && c == 0x2A && d == 0x00) // "II*\0"
            || (a == 0x4D && b == 0x4D && c == 0x00 && d == 0x2A) // "MM\0*"
    }
}
