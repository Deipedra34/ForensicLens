import Foundation
import ImageDecoding

/// The analyzed image, prepared for embedding directly in an HTML report
/// as a base64 `data:` URI.
///
/// Wherever a browser can display the original file as-is (BMP, JPEG),
/// the original bytes are embedded untouched -- no decode/re-encode round
/// trip, and the report shows exactly the file that was analyzed. PPM/PGM
/// are the exception: no browser renders them, so those are re-encoded
/// from the already-decoded `PixelBuffer` into a BMP, which every major
/// browser does render.
public struct EmbeddedImage: Sendable, Equatable {
    public let mimeType: String
    public let bytes: [UInt8]

    /// Pixel dimensions of the image, used as the overlay coordinate
    /// space. `nil` when the image couldn't be decoded to pixels (baseline
    /// JPEG -- see `ImageDecoder`); no analyzer can have produced a
    /// region for such an image anyway, so the report simply shows it
    /// without an overlay layer.
    public let width: Int?
    public let height: Int?

    public init(mimeType: String, bytes: [UInt8], width: Int?, height: Int?) {
        self.mimeType = mimeType
        self.bytes = bytes
        self.width = width
        self.height = height
    }

    /// Picks the cheapest browser-displayable representation of `image`,
    /// or returns `nil` if there's nothing displayable to embed.
    public static func from(_ image: ImageData) -> EmbeddedImage? {
        let width = image.pixels?.width
        let height = image.pixels?.height

        switch image.format {
        case .bmp?:
            return EmbeddedImage(mimeType: "image/bmp", bytes: image.rawBytes, width: width, height: height)
        case .jpeg?:
            return EmbeddedImage(mimeType: "image/jpeg", bytes: image.rawBytes, width: width, height: height)
        case .ppm?, .pgm?, nil:
            guard let pixels = image.pixels else { return nil }
            return EmbeddedImage(mimeType: "image/bmp", bytes: ImageEncoder.encodeBMP(pixels), width: pixels.width, height: pixels.height)
        }
    }

    /// The complete `data:` URI for an `<img src>` attribute.
    public var dataURI: String {
        "data:\(mimeType);base64,\(Data(bytes).base64EncodedString())"
    }
}
