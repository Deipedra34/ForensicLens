import CImageCodecs

/// HEIF/HEIC files, decoded by libheif (loaded at run time; see
/// `CodecLibrary`).
///
/// The result is the primary image as it's meant to be displayed: libheif
/// applies the file's rotation and mirroring, and higher bit depths are
/// reduced to 8 bits. Alpha, if any, is dropped. Every analyzer then sees an
/// ordinary 8-bit RGB `PixelBuffer`, the same as for any other format.
///
/// A missing libheif throws `ImageDecodingError.decoderUnavailable`; data
/// libheif rejects (corrupt, truncated, or needing a codec it lacks) throws
/// `ImageDecodingError.corruptData` with libheif's explanation.
struct HEIFDecoder: PixelDecoder {
    func decode(_ data: [UInt8]) throws -> PixelBuffer {
        try CodecBridge.decodeRGB(data, library: .libheif, using: cic_heif_decode_rgb)
    }
}
