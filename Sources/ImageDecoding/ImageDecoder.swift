import CStbImage

/// Decodes raw image bytes into a `PixelBuffer`.
///
/// `ImageDecoder` is the ONLY type in ForensicLens that imports `CStbImage`.
/// Every call into the C layer is funneled through the private helpers
/// below, which translate C error codes into `ImageDecodingError` and copy
/// the decoded bytes into a Swift `[UInt8]` before the C-owned buffer is
/// freed. Callers elsewhere in the package never see an unsafe pointer.
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
        switch format {
        case .bmp:
            return try decodeUsing(data, decoder: cstbi_decode_bmp)
        case .ppm, .pgm:
            return try decodeUsing(data, decoder: cstbi_decode_ppm)
        case .jpeg:
            // Deliberately routed through the same C entry point used by
            // ELAAnalyzer's documentation: a real JPEG decoder is a stub.
            // See cstbimage.h's doc comment on cstbi_decode_jpeg_baseline.
            return try decodeUsing(data, decoder: cstbi_decode_jpeg_baseline)
        }
    }

    /// Shared plumbing for the three `cstbi_decode_*` C functions, which all
    /// share the same `(data, len, &width, &height, &channels, &out) -> Int32`
    /// signature.
    private static func decodeUsing(
        _ data: [UInt8],
        decoder: (UnsafePointer<UInt8>?, Int, UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?) -> Int32
    ) throws -> PixelBuffer {
        var width: Int32 = 0
        var height: Int32 = 0
        var channels: Int32 = 0
        var outPixels: UnsafeMutablePointer<UInt8>?

        let code: Int32 = data.withUnsafeBufferPointer { buffer -> Int32 in
            decoder(buffer.baseAddress, buffer.count, &width, &height, &channels, &outPixels)
        }

        guard code == CSTBI_OK else {
            throw ImageDecodingError.from(cErrorCode: code)
        }
        guard let pixelsPointer = outPixels else {
            throw ImageDecodingError.allocationFailed
        }
        defer { cstbi_free(pixelsPointer) }

        let count = Int(width) * Int(height) * Int(channels)
        let bytes = Array(UnsafeBufferPointer(start: pixelsPointer, count: count))
        return try PixelBuffer(width: Int(width), height: Int(height), channels: Int(channels), pixels: bytes)
    }
}

extension ImageDecodingError {
    /// Maps a `CSTBI_ERR_*` code from the C layer to a typed Swift error.
    fileprivate static func from(cErrorCode code: Int32) -> ImageDecodingError {
        switch code {
        case CSTBI_ERR_TRUNCATED:
            return .truncatedData
        case CSTBI_ERR_BAD_MAGIC:
            return .badMagicNumber
        case CSTBI_ERR_UNSUPPORTED:
            return .unsupportedFormat("decoder rejected an unsupported variant (compression mode, bit depth, or color table)")
        case CSTBI_ERR_ALLOC:
            return .allocationFailed
        case CSTBI_ERR_DIMENSIONS:
            return .invalidDimensions(width: 0, height: 0, channels: 0)
        case CSTBI_ERR_NOT_IMPLEMENTED:
            return .notImplemented("baseline JPEG decoding is not implemented; see cstbimage.h")
        default:
            return .unknown(code: code)
        }
    }
}
