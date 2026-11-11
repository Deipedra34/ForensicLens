import CImageCodecs

/// WebP files (lossy VP8 or lossless VP8L, in the simple or extended
/// container), decoded by libwebp (loaded at run time; see `CodecLibrary`).
///
/// The result is 8-bit RGB; alpha, if any, is dropped, leaving the stored
/// color values. Animated WebP is rejected up front with a clear error,
/// since there's no single image to analyze.
///
/// A missing libwebp throws `ImageDecodingError.decoderUnavailable`; data
/// libwebp rejects throws `ImageDecodingError.corruptData`.
struct WebPDecoder: PixelDecoder {
    func decode(_ data: [UInt8]) throws -> PixelBuffer {
        if Self.isAnimated(data) {
            throw ImageDecodingError.unsupportedFormat("WebP: animated WebP files aren't supported, only still images")
        }
        return try CodecBridge.decodeRGB(data, library: .libwebp, using: cic_webp_decode_rgb)
    }

    /// An extended-format file (`VP8X` first chunk) with its animation flag set.
    static func isAnimated(_ data: [UInt8]) -> Bool {
        guard data.count >= 21, Array(data[12..<16]) == Array("VP8X".utf8) else { return false }
        return data[20] & 0x02 != 0
    }
}
