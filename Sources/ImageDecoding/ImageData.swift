/// The single unit of input that flows into every analyzer.
///
/// `ImageData` pairs the decoded `PixelBuffer` with the original file bytes
/// and detected container format. Keeping the raw bytes around matters more
/// than it might look: metadata analysis (EXIF) lives in file headers that
/// sit outside the compressed pixel stream, so `MetadataAnalyzer` reads
/// `rawBytes` directly and never touches pixels at all. Everything else in
/// the package — ELA, clone detection, the scorer, the CLI — only ever
/// looks at `pixels`. Neither side needs to know how the other one works,
/// which is the whole point of funneling all of this through one boundary
/// type.
public struct ImageData: Sendable {
    /// The original, unmodified file bytes as read from disk.
    public let rawBytes: [UInt8]

    /// The decoded pixel grid, if decoding succeeded. This is `nil` when the
    /// container format was recognized but pixel decoding isn't supported
    /// (baseline JPEG; see `cstbi_decode_jpeg_baseline`), which lets
    /// metadata-only analysis still proceed against `rawBytes`.
    public let pixels: PixelBuffer?

    /// The container format detected from `rawBytes`'s magic number, if any.
    public let format: ImageFormat?

    public init(rawBytes: [UInt8], pixels: PixelBuffer?, format: ImageFormat?) {
        self.rawBytes = rawBytes
        self.pixels = pixels
        self.format = format
    }

    /// Loads and decodes `rawBytes`, tolerating pixel-decode failures.
    ///
    /// Format detection and EXIF extraction don't require a successful pixel
    /// decode, so this only throws when the format itself is unrecognized.
    /// A `notImplemented` pixel-decode failure (baseline JPEG) is swallowed
    /// and surfaces as `pixels == nil` instead of a thrown error, since the
    /// caller may still want a metadata-only report.
    public static func load(_ rawBytes: [UInt8]) throws -> ImageData {
        guard let format = ImageFormat.detect(from: rawBytes) else {
            throw ImageDecodingError.badMagicNumber
        }
        do {
            let pixels = try ImageDecoder.decode(rawBytes, as: format)
            return ImageData(rawBytes: rawBytes, pixels: pixels, format: format)
        } catch ImageDecodingError.notImplemented(_) {
            return ImageData(rawBytes: rawBytes, pixels: nil, format: format)
        }
    }
}
