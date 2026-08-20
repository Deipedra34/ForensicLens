/// Encodes `PixelBuffer` values back into simple, dependency-free container
/// formats.
///
/// This mirrors `ImageDecoder` on purpose: PPM and BMP are the two formats
/// the package can round-trip without any C image library, which keeps the
/// test suite and CLI (e.g. dumping an ELA heat map for visual inspection)
/// fully self-contained.
public enum ImageEncoder {
    /// Encodes `buffer` as a binary PPM (P6) if it has 3 channels, or a
    /// binary PGM (P5) if it has 1 channel. Buffers with other channel
    /// counts (e.g. RGBA) are down-sampled to RGB by dropping the alpha
    /// channel.
    public static func encodePPM(_ buffer: PixelBuffer) -> [UInt8] {
        if buffer.channels == 1 {
            var header = Array("P5\n\(buffer.width) \(buffer.height)\n255\n".utf8)
            header.append(contentsOf: buffer.pixels)
            return header
        }

        var rgb: [UInt8] = []
        rgb.reserveCapacity(buffer.width * buffer.height * 3)
        for y in 0..<buffer.height {
            for x in 0..<buffer.width {
                let base = buffer.offset(x: x, y: y)
                rgb.append(buffer.pixels[base])
                rgb.append(buffer.pixels[base + 1])
                rgb.append(buffer.pixels[base + 2])
            }
        }
        var header = Array("P6\n\(buffer.width) \(buffer.height)\n255\n".utf8)
        header.append(contentsOf: rgb)
        return header
    }

    /// Encodes `buffer` as an uncompressed 24-bit BMP.
    public static func encodeBMP(_ buffer: PixelBuffer) -> [UInt8] {
        let width = buffer.width
        let height = buffer.height
        let rowSize = (width * 3 + 3) & ~3
        let pixelDataSize = rowSize * height
        let fileSize = 54 + pixelDataSize

        var bytes = [UInt8](repeating: 0, count: fileSize)

        // BITMAPFILEHEADER
        bytes[0] = 0x42 // 'B'
        bytes[1] = 0x4D // 'M'
        writeU32LE(&bytes, at: 2, UInt32(fileSize))
        writeU32LE(&bytes, at: 10, 54) // pixel data offset

        // BITMAPINFOHEADER
        writeU32LE(&bytes, at: 14, 40) // header size
        writeI32LE(&bytes, at: 18, Int32(width))
        writeI32LE(&bytes, at: 22, Int32(height)) // positive => bottom-up
        writeU16LE(&bytes, at: 26, 1) // planes
        writeU16LE(&bytes, at: 28, 24) // bit count
        writeU32LE(&bytes, at: 30, 0) // BI_RGB
        writeU32LE(&bytes, at: 34, UInt32(pixelDataSize))

        for row in 0..<height {
            let srcRow = height - 1 - row // BMP is bottom-up
            let rowStart = 54 + row * rowSize
            for col in 0..<width {
                let base = buffer.offset(x: col, y: srcRow)
                let r: UInt8
                let g: UInt8
                let b: UInt8
                if buffer.channels >= 3 {
                    r = buffer.pixels[base]
                    g = buffer.pixels[base + 1]
                    b = buffer.pixels[base + 2]
                } else {
                    r = buffer.pixels[base]
                    g = r
                    b = r
                }
                let dst = rowStart + col * 3
                bytes[dst] = b
                bytes[dst + 1] = g
                bytes[dst + 2] = r
            }
        }
        return bytes
    }

    private static func writeU32LE(_ bytes: inout [UInt8], at index: Int, _ value: UInt32) {
        bytes[index] = UInt8(value & 0xFF)
        bytes[index + 1] = UInt8((value >> 8) & 0xFF)
        bytes[index + 2] = UInt8((value >> 16) & 0xFF)
        bytes[index + 3] = UInt8((value >> 24) & 0xFF)
    }

    private static func writeI32LE(_ bytes: inout [UInt8], at index: Int, _ value: Int32) {
        writeU32LE(&bytes, at: index, UInt32(bitPattern: value))
    }

    private static func writeU16LE(_ bytes: inout [UInt8], at index: Int, _ value: UInt16) {
        bytes[index] = UInt8(value & 0xFF)
        bytes[index + 1] = UInt8((value >> 8) & 0xFF)
    }
}
