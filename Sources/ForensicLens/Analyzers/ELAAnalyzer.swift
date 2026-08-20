import Foundation
import ImageDecoding

/// Detects localized editing by re-compressing an image and measuring how
/// much each region changes.
///
/// A JPEG loses a bit of detail every time it gets re-saved, but it loses
/// it evenly across a region that was compressed once at a uniform
/// quality. Paste a clean (or differently-compressed) patch into an
/// already-JPEG'd photo and save the result, and that patch responds to a
/// fresh recompression pass differently than pixels that have already been
/// through one or more compression cycles. So: recompress the whole image
/// at a known quality, diff it pixel by pixel against the original, and
/// the pasted region tends to light up with a noticeably different error
/// level than everything around it. That's Error Level Analysis.
///
/// ForensicLens doesn't carry a full JPEG decoder (see
/// `cstbi_decode_jpeg_baseline`'s doc comment for why), so rather than
/// decoding and re-encoding an actual JPEG file, this analyzer just
/// simulates one recompression pass directly against the decoded
/// `PixelBuffer` — an 8x8 block DCT, quantization at the configured
/// quality, dequantization, then an inverse DCT. That's the exact lossy
/// step a real JPEG encoder performs, so running it once here reproduces
/// the same blocky error signature ELA is looking for, without needing
/// entropy coding, chroma subsampling, or any actual file format. Bonus:
/// it means ELA works the same way on every format this package can
/// decode (BMP, PPM), not just JPEGs.
///
/// The one knob that really matters here is `qualityLevel`, and it's a
/// trade-off. Quantize more aggressively (lower quality) and the
/// recompression pass gets louder everywhere — genuine edits stand out
/// more against the noise, but so does ordinary image content like sharp
/// edges and fine texture, which pushes up false positives. Go the other
/// way and near-lossless quantization leaves untouched regions barely
/// moving, but a subtle edit's error signature can shrink below
/// `errorThreshold` and slip past unnoticed. There's no value that's
/// "correct" for every image; `forensiclens.yaml`'s default of 75 mirrors
/// the "save for web" quality most photo editors default to, which is a
/// reasonable middle ground for a photo that's probably been re-saved
/// through one already.
public struct ELAAnalyzer: Analyzer {
    public let identifier = "ela"
    public let displayName = "Error Level Analysis"

    public init() {}

    public func analyze(_ image: ImageData, config: ForensicLensConfig) throws -> AnalyzerFinding {
        guard let buffer = image.pixels else {
            throw AnalyzerError.unsupportedInput("ELA requires decoded pixel data, but this image has none (its format's pixel decoder is a documented stub -- see ImageDecoder).")
        }

        let quality = max(1, min(100, config.ela.qualityLevel))
        let recompressed = JPEGRecompressionSimulator.recompress(buffer, quality: quality)
        let errorMap = Self.errorMap(original: buffer, recompressed: recompressed)

        let reportingCellSize = 16
        let cells = Self.aggregate(errorMap, width: buffer.width, height: buffer.height, cellSize: reportingCellSize)

        let threshold = config.ela.errorThreshold
        let hotCells = cells.filter { $0.meanError >= threshold }
        let totalArea = cells.reduce(0) { $0 + $1.pixelCount }
        let hotArea = hotCells.reduce(0) { $0 + $1.pixelCount }
        let hotFraction = totalArea > 0 ? Double(hotArea) / Double(totalArea) : 0

        let meanError = errorMap.isEmpty ? 0 : errorMap.reduce(0, +) / Double(errorMap.count)
        let maxCellError = hotCells.map(\.meanError).max() ?? cells.map(\.meanError).max() ?? 0

        let coverageFraction = max(config.ela.flaggedRegionFraction, 0.0001)
        let coverageScore = min(60, (hotFraction / coverageFraction) * 60)
        let intensityScore = min(40, (maxCellError / max(threshold * 2, 1)) * 40)
        let score = coverageScore + intensityScore

        var indicators: [Indicator] = []
        if !hotCells.isEmpty {
            let percent = String(format: "%.1f", hotFraction * 100)
            indicators.append(Indicator(
                message: "\(percent)% of the image falls inside \(hotCells.count) region(s) with recompression error at or above \(String(format: "%.1f", threshold)) (expected background level for an untouched image is well below this).",
                weight: coverageScore
            ))

            for cell in hotCells.sorted(by: { $0.meanError > $1.meanError }).prefix(5) {
                indicators.append(Indicator(
                    message: "Region (\(cell.x),\(cell.y))-(\(cell.x + cell.width),\(cell.y + cell.height)) shows a mean error level of \(String(format: "%.1f", cell.meanError)), notably higher than the image average of \(String(format: "%.1f", meanError)).",
                    weight: min(40, cell.meanError / max(threshold, 1) * 10)
                ))
            }
        }

        let summary: String
        if hotCells.isEmpty {
            summary = "No localized error-level anomalies detected; error is evenly distributed (mean \(String(format: "%.1f", meanError)))."
        } else {
            summary = "\(hotCells.count) region(s) show error levels inconsistent with a single uniform compression history."
        }

        return AnalyzerFinding(analyzerID: identifier, score: score, summary: summary, indicators: indicators)
    }

    /// Per-pixel error, expressed as the mean absolute difference across
    /// color channels between `original` and `recompressed`, on a 0...255
    /// scale.
    private static func errorMap(original: PixelBuffer, recompressed: PixelBuffer) -> [Double] {
        var map = [Double](repeating: 0, count: original.width * original.height)
        let channels = min(original.channels, recompressed.channels, 3)
        guard channels > 0 else { return map }

        for y in 0..<original.height {
            for x in 0..<original.width {
                let a = original.offset(x: x, y: y)
                let b = recompressed.offset(x: x, y: y)
                var sum = 0.0
                for c in 0..<channels {
                    let diff = Double(original.pixels[a + c]) - Double(recompressed.pixels[b + c])
                    sum += abs(diff)
                }
                map[y * original.width + x] = sum / Double(channels)
            }
        }
        return map
    }

    /// A rectangular reporting cell used to summarize the pixel-level error
    /// map into a small, human-readable list of "regions" without doing
    /// full connected-component labeling.
    private struct ErrorCell {
        let x: Int
        let y: Int
        let width: Int
        let height: Int
        let meanError: Double
        let pixelCount: Int
    }

    private static func aggregate(_ errorMap: [Double], width: Int, height: Int, cellSize: Int) -> [ErrorCell] {
        guard width > 0, height > 0, !errorMap.isEmpty else { return [] }
        var cells: [ErrorCell] = []
        var cy = 0
        while cy < height {
            let cellHeight = min(cellSize, height - cy)
            var cx = 0
            while cx < width {
                let cellWidth = min(cellSize, width - cx)
                var sum = 0.0
                for y in cy..<(cy + cellHeight) {
                    let rowBase = y * width
                    for x in cx..<(cx + cellWidth) {
                        sum += errorMap[rowBase + x]
                    }
                }
                let count = cellWidth * cellHeight
                cells.append(ErrorCell(x: cx, y: cy, width: cellWidth, height: cellHeight, meanError: sum / Double(count), pixelCount: count))
                cx += cellSize
            }
            cy += cellSize
        }
        return cells
    }
}

/// A minimal, self-contained simulator of one JPEG-style lossy
/// recompression pass, used by `ELAAnalyzer`.
///
/// It implements exactly the lossy part of baseline JPEG encoding (level
/// shift, forward DCT, quantize, dequantize, inverse DCT) and nothing
/// else — no chroma subsampling, no entropy coding, no file format at all.
/// It works directly on `PixelBuffer`, which is what lets `ELAAnalyzer`
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
