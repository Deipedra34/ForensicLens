import CStbImage

/// BMP files, decoded by `cstbi_decode_bmp`.
struct BMPDecoder: PixelDecoder {
    func decode(_ data: [UInt8]) throws -> PixelBuffer {
        try CStbImageBridge.decode(data, using: cstbi_decode_bmp)
    }
}

/// Binary PPM (P6) and PGM (P5) files, decoded by `cstbi_decode_ppm`.
struct NetpbmDecoder: PixelDecoder {
    func decode(_ data: [UInt8]) throws -> PixelBuffer {
        try CStbImageBridge.decode(data, using: cstbi_decode_ppm)
    }
}

/// JPEG files. Routed through the stub entry point ELAAnalyzer's docs
/// mention -- there's no real JPEG decoder here yet, so this always throws
/// `ImageDecodingError.notImplemented`, which `ImageData.load` turns into a
/// metadata-only image. See cstbimage.h's doc comment on
/// `cstbi_decode_jpeg_baseline`.
struct JPEGStubDecoder: PixelDecoder {
    func decode(_ data: [UInt8]) throws -> PixelBuffer {
        try CStbImageBridge.decode(data, using: cstbi_decode_jpeg_baseline)
    }
}

/// Shared plumbing for the `cstbi_decode_*` C functions, which all share the
/// same `(data, len, &width, &height, &channels, &out) -> Int32` signature.
/// Translates C error codes into `ImageDecodingError` and copies the decoded
/// bytes into a Swift `[UInt8]` before the C-owned buffer is freed.
enum CStbImageBridge {
    typealias DecodeFunction = (UnsafePointer<UInt8>?, Int, UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?) -> Int32

    static func decode(_ data: [UInt8], using decoder: DecodeFunction) throws -> PixelBuffer {
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
