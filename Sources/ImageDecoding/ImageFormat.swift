/// Image container formats this package can identify by magic number.
///
/// ForensicLens deliberately supports a small set of formats end-to-end
/// (BMP and binary PPM/PGM) so that the entire test suite can build
/// synthetic fixtures in-process without shelling out to an external image
/// library or shipping binary test assets. JPEG detection is included so
/// that callers get a clear, typed error (`ImageDecodingError.notImplemented`)
/// instead of a confusing parse failure when they point the CLI at a real
/// photo -- see `ELAAnalyzer` for how Error Level Analysis works around the
/// lack of a real JPEG decoder.
public enum ImageFormat: String, Sendable, CaseIterable {
    case bmp
    case ppm
    case pgm
    case jpeg

    /// Sniffs the format of `data` by inspecting its leading magic bytes.
    ///
    /// - Returns: The detected format, or `nil` if no known magic number
    ///   matches.
    public static func detect(from data: [UInt8]) -> ImageFormat? {
        guard data.count >= 2 else { return nil }
        if data[0] == 0x42, data[1] == 0x4D { // "BM"
            return .bmp
        }
        if data[0] == 0xFF, data[1] == 0xD8 { // JPEG SOI marker
            return .jpeg
        }
        if data[0] == 0x50 { // 'P'
            if data[1] == 0x36 { return .ppm } // "P6"
            if data[1] == 0x35 { return .pgm } // "P5"
        }
        return nil
    }
}
