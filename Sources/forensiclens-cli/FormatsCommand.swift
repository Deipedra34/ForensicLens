import ImageDecoding

/// `forensiclens-cli formats`: the image formats this build recognizes, how
/// each is decoded, and -- for HEIF/HEIC and WebP, whose codec libraries are
/// loaded at run time -- whether that library was found. Mostly a setup
/// check: it's how a user confirms `brew install libheif` (or the apt
/// equivalent) actually took effect.
enum FormatsCommand {
    static func report() -> String {
        var lines = ["Image formats recognized by this build:", ""]
        let rows: [(name: String, formats: [ImageFormat], support: String)] = [
            ("BMP", [.bmp], "decoded (built in): every analyzer"),
            ("PPM/PGM", [.ppm, .pgm], "decoded (built in): every analyzer"),
            ("JPEG", [.jpeg], "metadata only: EXIF analysis and the EXIF thumbnail check (JPEG pixels aren't decoded yet)"),
            ("HEIF/HEIC", [.heif], codecSupport(.libheif)),
            ("WebP", [.webp], codecSupport(.libwebp)),
        ]
        for row in rows {
            let extensions = row.formats.flatMap(\.fileExtensions).map { ".\($0)" }.joined(separator: " ")
            lines.append(padded(row.name, to: 11) + padded(extensions, to: 20) + row.support)
        }
        lines.append("")
        lines.append("HEIF/HEIC and WebP skip the JPEG-specific analyzers (ELA, double compression, JPEG ghost),")
        lines.append("which report \"not applicable\" for them; every other analyzer runs on the decoded pixels.")
        return lines.joined(separator: "\n")
    }

    private static func codecSupport(_ library: CodecLibrary) -> String {
        switch library.status {
        case .available(let description):
            return "decoded by \(description)"
        case .unavailable(let reason):
            return "NOT AVAILABLE: \(reason). \(library.installHint)"
        }
    }

    private static func padded(_ text: String, to width: Int) -> String {
        text.count >= width ? text + " " : text + String(repeating: " ", count: width - text.count)
    }
}
