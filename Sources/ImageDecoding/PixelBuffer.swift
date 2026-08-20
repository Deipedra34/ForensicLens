/// A decoded, in-memory raster image.
///
/// `PixelBuffer` is the single currency type that crosses the boundary
/// between the C decoding layer (`CStbImage`) and the rest of ForensicLens.
/// Every analyzer, the scorer, and the CLI work exclusively with this type;
/// none of them ever see a C pointer, a file format quirk, or an
/// `UnsafeMutablePointer`. That isolation is the point: it means new image
/// formats can be added later (or a real JPEG decoder swapped in) by
/// touching only this one module.
///
/// Pixel data is stored top-to-bottom, left-to-right, with `channels`
/// interleaved bytes per pixel (commonly 1 for grayscale or 3 for RGB).
public struct PixelBuffer: Sendable, Equatable {
    /// Image width in pixels. Always greater than zero for a valid buffer.
    public let width: Int

    /// Image height in pixels. Always greater than zero for a valid buffer.
    public let height: Int

    /// Number of interleaved color channels per pixel (e.g. 1 = grayscale,
    /// 3 = RGB, 4 = RGBA).
    public let channels: Int

    /// Raw interleaved pixel bytes, `width * height * channels` in length.
    public let pixels: [UInt8]

    /// Creates a pixel buffer, validating that `pixels.count` matches the
    /// declared dimensions.
    ///
    /// - Throws: `ImageDecodingError.dimensionMismatch` if the byte count
    ///   does not equal `width * height * channels`.
    public init(width: Int, height: Int, channels: Int, pixels: [UInt8]) throws {
        guard width > 0, height > 0, channels > 0 else {
            throw ImageDecodingError.invalidDimensions(width: width, height: height, channels: channels)
        }
        let expected = width * height * channels
        guard pixels.count == expected else {
            throw ImageDecodingError.dimensionMismatch(expected: expected, actual: pixels.count)
        }
        self.width = width
        self.height = height
        self.channels = channels
        self.pixels = pixels
    }

    /// Returns the byte offset of pixel `(x, y)` within `pixels`.
    @inlinable
    public func offset(x: Int, y: Int) -> Int {
        (y * width + x) * channels
    }

    /// Returns the channel values for the pixel at `(x, y)`.
    ///
    /// - Precondition: `x` and `y` must be within bounds. Callers in
    ///   performance-sensitive loops (e.g. clone detection) should prefer
    ///   indexing `pixels` directly with `offset(x:y:)` after validating
    ///   bounds once, rather than calling this per-pixel.
    public func pixel(x: Int, y: Int) -> [UInt8] {
        guard x >= 0, x < width, y >= 0, y < height else { return [] }
        let base = offset(x: x, y: y)
        return Array(pixels[base..<base + channels])
    }

    /// Computes a grayscale (luma) value for pixel `(x, y)` using the
    /// standard Rec. 601 luma coefficients when the buffer has 3+ channels,
    /// or the raw single-channel value otherwise.
    @inlinable
    public func luma(x: Int, y: Int) -> UInt8 {
        let base = offset(x: x, y: y)
        if channels >= 3 {
            let r = Double(pixels[base])
            let g = Double(pixels[base + 1])
            let b = Double(pixels[base + 2])
            let value = 0.299 * r + 0.587 * g + 0.114 * b
            return UInt8(clamping: Int(value.rounded()))
        } else {
            return pixels[base]
        }
    }
}

/// Errors that can occur while decoding or constructing image data.
public enum ImageDecodingError: Error, Equatable, CustomStringConvertible {
    /// The input bytes were too short to contain a valid header or the
    /// declared pixel payload.
    case truncatedData

    /// The file did not start with a magic number this decoder recognizes.
    case badMagicNumber

    /// The file uses a feature (compression mode, bit depth, color table)
    /// that this minimal decoder does not implement.
    case unsupportedFormat(String)

    /// The declared width/height were zero, negative, or unreasonably large.
    case invalidDimensions(width: Int, height: Int, channels: Int)

    /// `pixels.count` did not match `width * height * channels`.
    case dimensionMismatch(expected: Int, actual: Int)

    /// Memory allocation failed inside the C decoding layer.
    case allocationFailed

    /// The requested codec path (currently: real JPEG decoding) is a
    /// documented stub. See `cstbi_decode_jpeg_baseline` for rationale.
    case notImplemented(String)

    /// An unrecognized error code was returned from the C layer.
    case unknown(code: Int32)

    public var description: String {
        switch self {
        case .truncatedData:
            return "Image data is truncated or shorter than its header declares."
        case .badMagicNumber:
            return "Image data does not start with a recognized magic number."
        case .unsupportedFormat(let detail):
            return "Unsupported image format variant: \(detail)"
        case .invalidDimensions(let w, let h, let c):
            return "Invalid image dimensions: \(w)x\(h) with \(c) channels."
        case .dimensionMismatch(let expected, let actual):
            return "Pixel buffer size \(actual) does not match expected \(expected)."
        case .allocationFailed:
            return "Memory allocation failed while decoding the image."
        case .notImplemented(let detail):
            return "Not implemented: \(detail)"
        case .unknown(let code):
            return "Unknown image decoding error (code \(code))."
        }
    }
}
