/// Decodes raw image bytes into a `PixelBuffer`.
///
/// `ImageDecoder` is the front door to decoding: it identifies the container
/// format and hands the bytes to that format's `PixelDecoder`. Each decoder
/// lives in its own file under `Decoders/` and is the only code that knows
/// how its format is decoded (and, for the C-backed ones, the only code that
/// touches C types). Callers elsewhere in the package never see an unsafe
/// pointer.
public enum ImageDecoder {
    /// Decodes `data`, auto-detecting the container format from its magic
    /// number.
    ///
    /// - Parameter data: Raw file bytes.
    /// - Returns: A decoded `PixelBuffer`.
    /// - Throws: `ImageDecodingError.badMagicNumber` if the format cannot be
    ///   identified, or a format-specific error surfaced from the decoder.
    public static func decode(_ data: [UInt8]) throws -> PixelBuffer {
        guard let format = ImageFormat.detect(from: data) else {
            throw ImageDecodingError.badMagicNumber
        }
        return try decode(data, as: format)
    }

    /// Decodes `data` using an explicitly-specified format, bypassing magic
    /// number sniffing.
    public static func decode(_ data: [UInt8], as format: ImageFormat) throws -> PixelBuffer {
        try decoder(for: format).decode(data)
    }

    /// The decoder for `format`. An exhaustive switch on purpose: adding a
    /// case to `ImageFormat` doesn't compile until it has a decoder here.
    public static func decoder(for format: ImageFormat) -> any PixelDecoder {
        switch format {
        case .bmp:
            return BMPDecoder()
        case .ppm, .pgm:
            return NetpbmDecoder()
        case .jpeg:
            return JPEGStubDecoder()
        }
    }
}
