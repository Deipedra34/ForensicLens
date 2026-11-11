import CImageCodecs

/// Why `ImageEncoder.encodeWebP` / `encodeHEIF` failed.
public enum ImageEncodingError: Error, Equatable, CustomStringConvertible {
    /// The codec library isn't installed, or it has no encoder for the
    /// format (libheif needs an HEVC encoder plugin such as x265).
    case encoderUnavailable(String)
    /// The library was loaded but failed to encode the image.
    case failed(String)

    public var description: String {
        switch self {
        case .encoderUnavailable(let detail):
            return "Encoder unavailable: \(detail)"
        case .failed(let detail):
            return "Encoding failed: \(detail)"
        }
    }
}

extension ImageEncoder {
    /// Encodes `buffer` as a WebP file with libwebp: lossless when `quality`
    /// is `nil`, otherwise lossy at `quality` (0-100). Grayscale buffers are
    /// stored as RGB, and a fourth channel is dropped.
    ///
    /// Like the decoders, this loads libwebp at run time. ForensicLens
    /// itself never writes WebP; it's here so tests can build synthetic
    /// WebP fixtures in-process, the way they build BMP and PPM ones.
    public static func encodeWebP(_ buffer: PixelBuffer, quality: Int? = nil) throws -> [UInt8] {
        let rgb = rgbBytes(of: buffer)
        let width = Int32(buffer.width)
        let height = Int32(buffer.height)
        let encodedQuality = Int32(quality ?? -1)
        return try encodeUsing(.libwebp) { output, size, message, messageSize in
            rgb.withUnsafeBufferPointer { pixels in
                cic_webp_encode_rgb(pixels.baseAddress, width, height, encodedQuality, output, size, message, messageSize)
            }
        }
    }

    /// Encodes `buffer` as an HEVC-coded HEIF (HEIC) file with libheif:
    /// lossless when `quality` is `nil`, otherwise lossy at `quality`
    /// (0-100), with 4:4:4 chroma where the encoder supports it. `exif`
    /// (a TIFF-structured EXIF block, starting with `"II*\0"` or `"MM\0*"`)
    /// is stored as the image's Exif metadata item.
    ///
    /// Needs libheif with an HEVC encoder at run time. Here for building
    /// test fixtures, like `encodeWebP`.
    public static func encodeHEIF(_ buffer: PixelBuffer, quality: Int? = nil, exif: [UInt8]? = nil) throws -> [UInt8] {
        let rgb = rgbBytes(of: buffer)
        let width = Int32(buffer.width)
        let height = Int32(buffer.height)
        let encodedQuality = Int32(quality ?? -1)
        let exifBytes = exif ?? []
        return try encodeUsing(.libheif) { output, size, message, messageSize in
            rgb.withUnsafeBufferPointer { pixels in
                exifBytes.withUnsafeBufferPointer { exifPointer in
                    cic_heif_encode_rgb(pixels.baseAddress, width, height, encodedQuality,
                                        exifBytes.isEmpty ? nil : exifPointer.baseAddress, exifBytes.count,
                                        output, size, message, messageSize)
                }
            }
        }
    }

    /// `buffer` as tightly packed 8-bit RGB.
    static func rgbBytes(of buffer: PixelBuffer) -> [UInt8] {
        if buffer.channels == 3 {
            return buffer.pixels
        }
        var rgb: [UInt8] = []
        rgb.reserveCapacity(buffer.width * buffer.height * 3)
        for y in 0..<buffer.height {
            for x in 0..<buffer.width {
                let base = buffer.offset(x: x, y: y)
                if buffer.channels < 3 {
                    let value = buffer.pixels[base]
                    rgb.append(contentsOf: [value, value, value])
                } else {
                    rgb.append(contentsOf: buffer.pixels[base..<(base + 3)])
                }
            }
        }
        return rgb
    }

    private typealias EncodeCall = (UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?, UnsafeMutablePointer<Int>?, UnsafeMutablePointer<CChar>?, Int) -> Int32

    private static func encodeUsing(_ library: CodecLibrary, _ call: EncodeCall) throws -> [UInt8] {
        var output: UnsafeMutablePointer<UInt8>?
        var size = 0
        var message = [CChar](repeating: 0, count: 1400)
        let code = message.withUnsafeMutableBufferPointer { text in
            call(&output, &size, text.baseAddress, text.count)
        }
        defer { cic_free(output) }

        let text = CodecMessage.string(from: message)
        switch code {
        case CIC_OK:
            guard let output, size > 0 else {
                throw ImageEncodingError.failed("\(library.rawValue) produced no output")
            }
            return Array(UnsafeBufferPointer(start: output, count: size))
        case CIC_ERR_UNAVAILABLE, CIC_ERR_NO_ENCODER:
            throw ImageEncodingError.encoderUnavailable("\(library.rawValue): \(text)")
        default:
            throw ImageEncodingError.failed("\(library.rawValue): \(text)")
        }
    }
}
