/// Image container formats this package can identify by magic number.
///
/// BMP and binary PPM/PGM are decoded by the package's own C code, which is
/// what lets the whole test suite build synthetic fixtures in-process
/// without an external image library. JPEG detection is included so callers
/// get a clear, typed error (`ImageDecodingError.notImplemented`) and a
/// metadata-only analysis instead of a confusing parse failure; see
/// `ELAAnalyzer` for how Error Level Analysis works around not having a real
/// JPEG decoder. HEIF/HEIC and WebP are decoded by libheif and libwebp,
/// loaded at run time (see `CodecLibrary`).
public enum ImageFormat: String, Sendable, CaseIterable {
    case bmp
    case ppm
    case pgm
    case jpeg
    /// HEIF and HEIC (HEVC-coded HEIF, the iPhone camera default).
    case heif
    /// WebP, lossy (VP8) or lossless (VP8L).
    case webp

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
        if isHEIF(data) {
            return .heif
        }
        if isWebP(data) {
            return .webp
        }
        return nil
    }

    /// A RIFF container (`"RIFF" <size> "WEBP"`).
    private static func isWebP(_ data: [UInt8]) -> Bool {
        data.count >= 12
            && Array(data[0..<4]) == Array("RIFF".utf8)
            && Array(data[8..<12]) == Array("WEBP".utf8)
    }

    /// Brands that mean HEVC-coded HEIF (HEIC) content.
    static let hevcBrands: Set<String> = ["heic", "heix", "heim", "heis", "hevc", "hevx", "hevm", "hevs"]

    /// Brands of the generic HEIF structure, used alongside or instead of
    /// the HEVC-specific ones.
    static let heifStructuralBrands: Set<String> = ["mif1", "mif2", "msf1"]

    /// An ISO base media file starting with an `ftyp` box whose brands mark
    /// it as HEIF. AVIF files are HEIF-structured too (they list `mif1`),
    /// but with AV1 instead of HEVC content; they aren't claimed here unless
    /// they also carry an HEVC brand.
    private static func isHEIF(_ data: [UInt8]) -> Bool {
        guard data.count >= 16, data[4] == 0x66, data[5] == 0x74, data[6] == 0x79, data[7] == 0x70 else { // "ftyp"
            return false
        }
        let declaredSize = Int(data[0]) << 24 | Int(data[1]) << 16 | Int(data[2]) << 8 | Int(data[3])
        guard declaredSize >= 16 else { return false }
        let boxEnd = min(declaredSize, data.count)

        func brand(at offset: Int) -> String {
            String(decoding: data[offset..<(offset + 4)], as: UTF8.self)
        }
        var brands = [brand(at: 8)]
        var offset = 16
        while offset + 4 <= boxEnd {
            brands.append(brand(at: offset))
            offset += 4
        }

        if brands.contains(where: hevcBrands.contains) {
            return true
        }
        if brands.contains("avif") || brands.contains("avis") {
            return false
        }
        return brands.contains(where: heifStructuralBrands.contains)
    }
}
