import CImageCodecs

/// A system image codec library that ForensicLens loads at run time.
///
/// HEIF/HEIC and WebP decoding is done by libheif and libwebp, but neither
/// is linked at build time: `CImageCodecs` opens them with `dlopen` the
/// first time they're needed. Building ForensicLens therefore needs nothing
/// beyond the Swift toolchain, exactly as before, and installing either
/// library later turns its format on without rebuilding. Until then, files
/// in that format fail to decode with `ImageDecodingError.decoderUnavailable`,
/// which names the missing library and how to install it.
///
/// The same code path is used on macOS and Linux. Libraries are looked up by
/// their usual names and Homebrew/MacPorts locations; the
/// `FORENSICLENS_LIBHEIF_PATH` / `FORENSICLENS_LIBWEBP_PATH` environment
/// variables point at a specific file instead.
public enum CodecLibrary: String, CaseIterable, Sendable {
    case libheif
    case libwebp

    /// Whether the library could be loaded, and either what was loaded or
    /// why not.
    public enum Status: Equatable, Sendable {
        /// Loaded; for example "libheif 1.17.6 (/usr/lib/x86_64-linux-gnu/libheif.so.1)".
        case available(description: String)
        /// Not loadable, with the reason.
        case unavailable(reason: String)
    }

    /// The library's status. Loading happens once per process; later calls
    /// just report the result.
    public var status: Status {
        var buffer = [CChar](repeating: 0, count: 1400)
        let code = buffer.withUnsafeMutableBufferPointer { message -> Int32 in
            switch self {
            case .libheif:
                return cic_heif_load(message.baseAddress, message.count)
            case .libwebp:
                return cic_webp_load(message.baseAddress, message.count)
            }
        }
        let text = CodecMessage.string(from: buffer)
        return code == CIC_OK ? .available(description: text) : .unavailable(reason: text)
    }

    public var isAvailable: Bool {
        if case .available = status { return true }
        return false
    }

    /// The image formats this library provides.
    public var formatName: String {
        switch self {
        case .libheif: return "HEIF/HEIC"
        case .libwebp: return "WebP"
        }
    }

    /// The environment variable that points ForensicLens at a specific copy
    /// of the library.
    public var pathEnvironmentVariable: String {
        switch self {
        case .libheif: return "FORENSICLENS_LIBHEIF_PATH"
        case .libwebp: return "FORENSICLENS_LIBWEBP_PATH"
        }
    }

    /// How to install the library on the platforms ForensicLens supports.
    public var installHint: String {
        switch self {
        case .libheif:
            return "Install libheif: `brew install libheif` on macOS, `sudo apt install libheif1 libheif-plugin-libde265` on Debian/Ubuntu (the plugin package exists from Ubuntu 24.04 / Debian 13 on), or `sudo dnf install libheif-freeworld` (RPM Fusion) on Fedora."
        case .libwebp:
            return "Install libwebp: `brew install webp` on macOS, `sudo apt install libwebp7` on Debian/Ubuntu, or `sudo dnf install libwebp` on Fedora."
        }
    }
}

/// Converts the NUL-terminated messages `CImageCodecs` writes into Swift strings.
enum CodecMessage {
    static func string(from buffer: [CChar]) -> String {
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
