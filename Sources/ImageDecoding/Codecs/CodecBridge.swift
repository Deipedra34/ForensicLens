import CImageCodecs

/// Shared plumbing for the `cic_*_decode_rgb` C functions, which all share
/// the same `(data, length, &width, &height, &out, message, messageSize)`
/// signature. Translates their status codes into `ImageDecodingError`
/// (keeping the library's own explanation) and copies the decoded RGB bytes
/// into a `PixelBuffer` before the C-owned buffer is freed.
enum CodecBridge {
    typealias DecodeFunction = (UnsafePointer<UInt8>?, Int, UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?, UnsafeMutablePointer<CChar>?, Int) -> Int32

    static func decodeRGB(_ data: [UInt8], library: CodecLibrary, using decode: DecodeFunction) throws -> PixelBuffer {
        guard !data.isEmpty else {
            throw ImageDecodingError.truncatedData
        }

        var width: Int32 = 0
        var height: Int32 = 0
        var pixels: UnsafeMutablePointer<UInt8>?
        var message = [CChar](repeating: 0, count: 1400)

        let code: Int32 = data.withUnsafeBufferPointer { bytes in
            message.withUnsafeMutableBufferPointer { text in
                decode(bytes.baseAddress, bytes.count, &width, &height, &pixels, text.baseAddress, text.count)
            }
        }

        guard code == CIC_OK else {
            throw error(for: code, message: CodecMessage.string(from: message), library: library)
        }
        guard let pixelsPointer = pixels else {
            throw ImageDecodingError.allocationFailed
        }
        defer { cic_free(pixelsPointer) }

        let count = Int(width) * Int(height) * 3
        let bytes = Array(UnsafeBufferPointer(start: pixelsPointer, count: count))
        return try PixelBuffer(width: Int(width), height: Int(height), channels: 3, pixels: bytes)
    }

    static func error(for code: Int32, message: String, library: CodecLibrary) -> ImageDecodingError {
        switch code {
        case CIC_ERR_UNAVAILABLE:
            return .decoderUnavailable("\(library.formatName) decoding needs \(library.rawValue), which couldn't be loaded: \(message). \(library.installHint)")
        case CIC_ERR_DECODE:
            return .corruptData("\(library.formatName): \(message)")
        case CIC_ERR_DIMENSIONS:
            return .unsupportedFormat("\(library.formatName): \(message)")
        case CIC_ERR_ALLOC:
            return .allocationFailed
        default:
            return .unknown(code: code)
        }
    }
}
