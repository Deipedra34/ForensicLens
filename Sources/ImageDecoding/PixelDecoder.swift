/// Turns one container format's bytes into a `PixelBuffer`.
///
/// Every format `ImageFormat` can identify has exactly one decoder, picked by
/// `ImageDecoder.decoder(for:)`. That's the whole extension point for new
/// formats: write a type conforming to this protocol in its own file and
/// return it from `decoder(for:)`. Nothing downstream changes -- the
/// analyzers, the engine, the CLI, and batch mode only ever see the
/// `PixelBuffer` a decoder produces, never how it was produced.
///
/// Conformers must not crash on malformed input: anything they can't decode
/// is reported as a thrown `ImageDecodingError`, which batch mode turns into
/// a skipped file.
public protocol PixelDecoder: Sendable {
    /// Decodes `data` (a complete file in this decoder's format).
    func decode(_ data: [UInt8]) throws -> PixelBuffer
}
