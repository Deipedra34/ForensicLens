import Foundation
import ImageDecoding

/// Synthetic camera JPEGs with embedded EXIF thumbnails, for the thumbnail
/// consistency tests: a textured scene, a thumbnail made from it the way
/// camera firmware does (an area-average downscale, saved as its own small
/// JPEG), and a file that puts the thumbnail in EXIF IFD1 in front of the
/// main image's JPEG stream.
extension Fixtures {
    /// A grayscale scene with texture and gradients: the smooth texture
    /// fixture blended with two sine waves.
    static func thumbnailScene(width: Int, height: Int) throws -> PixelBuffer {
        let texture = try smoothTextureBuffer(width: width, height: height, seed: 3)
        var pixels = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let value = 0.6 * Double(texture.pixels[y * width + x]) + 50 * sin(Double(x) / 40) + 30 * cos(Double(y) / 25) + 20
                pixels[y * width + x] = UInt8(clamping: Int(value))
            }
        }
        return try PixelBuffer(width: width, height: height, channels: 1, pixels: pixels)
    }

    /// `buffer` (grayscale) with the `size` x `size` region at `(x, y)`
    /// replaced by unrelated texture: an object pasted over the scene.
    static func pastingObject(into buffer: PixelBuffer, at x: Int, _ y: Int, size: Int) throws -> PixelBuffer {
        let object = try smoothTextureBuffer(width: size, height: size, seed: 99)
        var pixels = buffer.pixels
        for row in 0..<size {
            for col in 0..<size {
                pixels[(y + row) * buffer.width + x + col] = object.pixels[row * size + col]
            }
        }
        return try PixelBuffer(width: buffer.width, height: buffer.height, channels: 1, pixels: pixels)
    }

    /// The rows `top..<top + height` of a grayscale buffer.
    static func croppingRows(_ buffer: PixelBuffer, from top: Int, count: Int) throws -> PixelBuffer {
        try PixelBuffer(width: buffer.width, height: count, channels: 1, pixels: Array(buffer.pixels[(top * buffer.width)..<((top + count) * buffer.width)]))
    }

    /// Area-average downscale of a grayscale buffer, computed independently
    /// of the analyzer's own resampler.
    static func downscaled(_ buffer: PixelBuffer, toWidth width: Int, height: Int) throws -> PixelBuffer {
        var pixels = [UInt8](repeating: 0, count: width * height)
        let sx = Double(buffer.width) / Double(width)
        let sy = Double(buffer.height) / Double(height)
        for ty in 0..<height {
            for tx in 0..<width {
                var sum = 0.0
                var weight = 0.0
                var y = Double(ty) * sy
                while y < Double(ty + 1) * sy - 1e-9 {
                    let row = Int(y)
                    let rowWeight = min(Double(ty + 1) * sy, Double(row + 1)) - y
                    var x = Double(tx) * sx
                    while x < Double(tx + 1) * sx - 1e-9 {
                        let col = Int(x)
                        let colWeight = min(Double(tx + 1) * sx, Double(col + 1)) - x
                        sum += Double(buffer.pixels[row * buffer.width + col]) * rowWeight * colWeight
                        weight += rowWeight * colWeight
                        x = Double(col + 1)
                    }
                    y = Double(row + 1)
                }
                pixels[ty * width + tx] = UInt8(clamping: Int((sum / weight).rounded()))
            }
        }
        return try PixelBuffer(width: width, height: height, channels: 1, pixels: pixels)
    }

    /// A thumbnail JPEG (quality 75, as cameras typically use) of `buffer`.
    static func thumbnailJPEG(of buffer: PixelBuffer, width: Int, height: Int) throws -> [UInt8] {
        TestJPEGEncoder.encode(try downscaled(buffer, toWidth: width, height: height), quality: 75)
    }

    /// A 3:2 image's thumbnail stored the way some cameras do: a fixed 4:3
    /// frame with the content letterboxed between black bars.
    static func letterboxedThumbnailJPEG(of buffer: PixelBuffer, width: Int, height: Int) throws -> [UInt8] {
        let contentHeight = Int((Double(width) * Double(buffer.height) / Double(buffer.width)).rounded())
        let top = (height - contentHeight) / 2
        let content = try downscaled(buffer, toWidth: width, height: contentHeight)
        var pixels = [UInt8](repeating: 0, count: width * height)
        pixels.replaceSubrange((top * width)..<((top + contentHeight) * width), with: content.pixels)
        return TestJPEGEncoder.encode(try PixelBuffer(width: width, height: height, channels: 1, pixels: pixels), quality: 75)
    }

    /// A JPEG file: SOI, an APP1 Exif segment (IFD0 with a camera Make, and
    /// unless `thumbnail` is `nil`, IFD1 describing the thumbnail), then
    /// the rest of `mainJPEG`. `thumbnailCompression` 1 writes IFD1 as an
    /// uncompressed thumbnail with no JPEG pointer.
    static func jpegFile(main mainJPEG: [UInt8], thumbnail: [UInt8]?, thumbnailCompression: UInt16 = 6) -> [UInt8] {
        func u16(_ value: UInt16) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8)] }
        func u32(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8((value >> (8 * UInt32($0))) & 0xFF) } }
        func entry(_ tag: UInt16, _ type: UInt16, _ count: UInt32, _ value: [UInt8]) -> [UInt8] {
            u16(tag) + u16(type) + u32(count) + value + [UInt8](repeating: 0, count: 4 - value.count)
        }

        let make = Array("TestCam\0".utf8)
        let ifd0Start = 8
        let ifd1Start = ifd0Start + 2 + 12 + 4
        let ifd1Entries = thumbnail == nil ? 0 : (thumbnailCompression == 6 ? 3 : 1)
        let externalStart = ifd1Start + (ifd1Entries > 0 ? 2 + 12 * ifd1Entries + 4 : 0)
        let thumbnailStart = externalStart + make.count

        var tiff: [UInt8] = Array("II".utf8) + u16(42) + u32(UInt32(ifd0Start))
        tiff += u16(1) + entry(0x010F, 2, UInt32(make.count), u32(UInt32(externalStart)))
        tiff += u32(ifd1Entries > 0 ? UInt32(ifd1Start) : 0)
        if let thumbnail, ifd1Entries > 0 {
            tiff += u16(UInt16(ifd1Entries)) + entry(0x0103, 3, 1, u16(thumbnailCompression))
            if thumbnailCompression == 6 {
                tiff += entry(0x0201, 4, 1, u32(UInt32(thumbnailStart)))
                tiff += entry(0x0202, 4, 1, u32(UInt32(thumbnail.count)))
            }
            tiff += u32(0)
        }
        tiff += make
        if let thumbnail, thumbnailCompression == 6 { tiff += thumbnail }

        let payload = Array("Exif\0\0".utf8) + tiff
        let length = payload.count + 2
        return [0xFF, 0xD8, 0xFF, 0xE1, UInt8(length >> 8), UInt8(length & 0xFF)] + payload + Array(mainJPEG.dropFirst(2))
    }
}
