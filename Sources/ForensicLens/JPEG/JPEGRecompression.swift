import Foundation
import ImageDecoding

/// A minimal, self-contained simulator of one JPEG-style lossy
/// recompression pass, shared by every analyzer that needs to re-save an
/// image as JPEG: `ELAAnalyzer` (one pass per configured quality),
/// `JPEGGhostAnalyzer` (one pass per quality in its sweep), and the
/// double-compression tests that synthesize twice-compressed images.
///
/// It implements exactly the lossy part of baseline JPEG encoding (level
/// shift, forward DCT, quantize, dequantize, inverse DCT) and nothing
/// else — no chroma subsampling, no entropy coding, no file format at all.
/// It works directly on `PixelBuffer`, which is what lets those analyzers
/// run without a real JPEG codec behind it.
enum JPEGRecompressionSimulator {
    private static let blockSize = 8

    /// Standard IJG baseline luminance quantization table, applied
    /// per-channel here since ForensicLens's `PixelBuffer` doesn't carry
    /// chroma subsampling. This slightly overstates real-world JPEG
    /// sensitivity on chroma channels, which is an acceptable trade-off
    /// for a forensic heuristic rather than a spec-accurate encoder.
    private static let baseQuantTable: [Double] = [
        16, 11, 10, 16, 24, 40, 51, 61,
        12, 12, 14, 19, 26, 58, 60, 55,
        14, 13, 16, 24, 40, 57, 69, 56,
        14, 17, 22, 29, 51, 87, 80, 62,
        18, 22, 37, 56, 68, 109, 103, 77,
        24, 35, 55, 64, 81, 104, 113, 92,
        49, 64, 78, 87, 103, 121, 120, 101,
        72, 92, 95, 98, 112, 100, 103, 99
    ]

    /// Recompresses `buffer` at `quality` (1...100) and returns a new
    /// buffer of the same dimensions and channel count.
    static func recompress(_ buffer: PixelBuffer, quality: Int) -> PixelBuffer {
        let quantTable = scaledQuantTable(quality: quality)
        let colorChannels = min(buffer.channels, 3)
        var output = buffer.pixels

        for channel in 0..<colorChannels {
            recompressChannel(buffer, channel: channel, quantTable: quantTable, into: &output)
        }
        // Any channel beyond the first three (e.g. alpha) is left untouched
        // in `output`, which already starts as a copy of the original.

        // PixelBuffer's initializer only fails on a dimension/count
        // mismatch, and `output` is built from `buffer`'s own dimensions,
        // so this can never actually throw.
        return (try? PixelBuffer(width: buffer.width, height: buffer.height, channels: buffer.channels, pixels: output)) ?? buffer
    }

    private static func scaledQuantTable(quality: Int) -> [Double] {
        let q = max(1, min(100, quality))
        let scaleFactor: Double = q < 50 ? (5000.0 / Double(q)) : (200.0 - Double(q) * 2.0)
        return baseQuantTable.map { base in
            let scaled = ((base * scaleFactor) + 50) / 100
            return max(1, min(255, scaled.rounded(.down)))
        }
    }

    private static func recompressChannel(_ buffer: PixelBuffer, channel: Int, quantTable: [Double], into output: inout [UInt8]) {
        let width = buffer.width
        let height = buffer.height

        var by = 0
        while by < height {
            let blockHeight = min(blockSize, height - by)
            var bx = 0
            while bx < width {
                let blockWidth = min(blockSize, width - bx)

                // Extract an 8x8 block, replicating edge pixels so partial
                // blocks at the image border still get a full transform.
                var block = [Double](repeating: 0, count: blockSize * blockSize)
                for y in 0..<blockSize {
                    let srcY = min(by + y, by + blockHeight - 1)
                    for x in 0..<blockSize {
                        let srcX = min(bx + x, bx + blockWidth - 1)
                        let offset = buffer.offset(x: srcX, y: srcY) + channel
                        block[y * blockSize + x] = Double(buffer.pixels[offset]) - 128
                    }
                }

                let coefficients = DCT8x8.forward(block)
                var quantized = [Double](repeating: 0, count: blockSize * blockSize)
                for i in 0..<coefficients.count {
                    quantized[i] = (coefficients[i] / quantTable[i]).rounded() * quantTable[i]
                }
                let reconstructed = DCT8x8.inverse(quantized)

                for y in 0..<blockHeight {
                    let dstY = by + y
                    for x in 0..<blockWidth {
                        let dstX = bx + x
                        let value = reconstructed[y * blockSize + x] + 128
                        let clamped = UInt8(clamping: Int(value.rounded()))
                        output[buffer.offset(x: dstX, y: dstY) + channel] = clamped
                    }
                }

                bx += blockSize
            }
            by += blockSize
        }
    }
}

/// A direct (non-FFT) 8x8 two-dimensional DCT-II / DCT-III pair.
///
/// Block size is fixed at 8, matching JPEG, so a straightforward O(N^3)
/// separable implementation with a precomputed cosine table is plenty fast.
/// No real need to reach for an FFT here.
enum DCT8x8 {
    private static let n = 8
    private static let scale = (2.0 / 8.0).squareRoot()
    private static let invSqrt2 = 1.0 / 2.0.squareRoot()

    /// `cosTable[x][u] == cos((2x + 1) * u * pi / 16)`
    private static let cosTable: [[Double]] = {
        var table = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        for x in 0..<n {
            for u in 0..<n {
                table[x][u] = cos((2.0 * Double(x) + 1.0) * Double(u) * Double.pi / 16.0)
            }
        }
        return table
    }()

    private static func alpha(_ u: Int) -> Double {
        u == 0 ? invSqrt2 : 1.0
    }

    /// Forward 2D DCT of an 8x8 block, stored row-major.
    static func forward(_ block: [Double]) -> [Double] {
        var rows = [Double](repeating: 0, count: n * n)
        for y in 0..<n {
            for u in 0..<n {
                var sum = 0.0
                for x in 0..<n { sum += block[y * n + x] * cosTable[x][u] }
                rows[y * n + u] = scale * alpha(u) * sum
            }
        }
        var result = [Double](repeating: 0, count: n * n)
        for u in 0..<n {
            for v in 0..<n {
                var sum = 0.0
                for y in 0..<n { sum += rows[y * n + u] * cosTable[y][v] }
                result[v * n + u] = scale * alpha(v) * sum
            }
        }
        return result
    }

    /// Inverse 2D DCT (DCT-III) of an 8x8 coefficient block, stored row-major.
    static func inverse(_ coefficients: [Double]) -> [Double] {
        var rows = [Double](repeating: 0, count: n * n)
        for v in 0..<n {
            for x in 0..<n {
                var sum = 0.0
                for u in 0..<n { sum += alpha(u) * coefficients[v * n + u] * cosTable[x][u] }
                rows[v * n + x] = scale * sum
            }
        }
        var result = [Double](repeating: 0, count: n * n)
        for x in 0..<n {
            for y in 0..<n {
                var sum = 0.0
                for v in 0..<n { sum += alpha(v) * rows[v * n + x] * cosTable[y][v] }
                result[y * n + x] = scale * sum
            }
        }
        return result
    }
}
