import ImageDecoding

/// One block of a `JPEGGhostMap`.
public struct JPEGGhostBlock: Sendable, Equatable {
    public enum Status: String, Sendable, Equatable {
        /// The block's ghost quality matches the image's dominant quality.
        case consistent
        /// The block's ghost quality is at least `disagreementThreshold`
        /// away from the dominant quality.
        case inconsistent
        /// Not judged: the block is too flat for re-compression to change it
        /// measurably, or its curve shows no ghost at all.
        case unreliable
    }

    /// The block's area, in image pixel coordinates.
    public let region: Region

    public let status: Status

    /// The block's ghost quality (`JPEGGhostMath.ghostQuality`), if any.
    public let ghostQuality: Int?
}

/// The per-block result of JPEG ghost analysis, in row-major block order.
public struct JPEGGhostMap: Sendable, Equatable {
    public let columns: Int
    public let rows: Int
    public let blocks: [JPEGGhostBlock]

    /// The qualities swept, ascending.
    public let qualities: [Int]

    /// How many blocks had enough detail to measure (whether or not their
    /// curve shows a ghost).
    public let measuredBlockCount: Int

    /// The most common block ghost quality, or `nil` when the image shows
    /// no usable JPEG compression history (see `historyPresent`).
    public let dominantQuality: Int?

    /// Whether at least `JPEGGhostAnalysis.minimumHistoryFraction` of the
    /// measured blocks show a ghost. A never-compressed image has none: its
    /// curves fall steadily toward quality 100.
    public var historyPresent: Bool { dominantQuality != nil }

    public var judgedBlocks: [JPEGGhostBlock] {
        blocks.filter { $0.status != .unreliable }
    }

    public var inconsistentBlocks: [JPEGGhostBlock] {
        blocks.filter { $0.status == .inconsistent }
    }
}

/// The quality sweep: re-compresses the image's luminance once per quality
/// with the shared `JPEGRecompressionSimulator`, builds every block's
/// difference curve, and compares each block's ghost quality against the
/// image's dominant one.
///
/// Only luminance is swept. A JPEG encoder quantizes luminance with exactly
/// the table the simulator uses, at full resolution, while chroma gets a
/// different table and is usually subsampled, so luminance carries the
/// cleanest ghosts. One channel instead of three also cuts the cost of the
/// sweep by about two thirds.
enum JPEGGhostAnalysis {
    /// A block whose largest difference across the sweep is below this
    /// (mean squared difference, in squared gray levels) is too flat to judge.
    static let minimumMeasurableDifference = 0.5

    /// Share of measured blocks that must show a ghost for the image to
    /// count as having a JPEG compression history.
    static let minimumHistoryFraction = 0.5

    /// Builds the map for `buffer` over non-overlapping `blockSize` blocks
    /// (a multiple of 8, so blocks line up with the 8x8 JPEG grid anchored at
    /// the top-left corner). Partial blocks at the right and bottom edges are
    /// left out.
    static func map(_ buffer: PixelBuffer, qualities: [Int], blockSize: Int, disagreementThreshold: Int) -> JPEGGhostMap {
        let columns = blockSize > 0 ? buffer.width / blockSize : 0
        let rows = blockSize > 0 ? buffer.height / blockSize : 0
        guard columns > 0, rows > 0, !qualities.isEmpty, let luma = luminance(of: buffer) else {
            return JPEGGhostMap(columns: 0, rows: 0, blocks: [], qualities: qualities, measuredBlockCount: 0, dominantQuality: nil)
        }

        // curves[block][qualityIndex], built one re-compression at a time so
        // only one re-compressed copy of the image is ever held.
        var curves = [[Double]](repeating: [Double](repeating: 0, count: qualities.count), count: columns * rows)
        for (index, quality) in qualities.enumerated() {
            let recompressed = JPEGRecompressionSimulator.recompress(luma, quality: quality)
            let differences = JPEGGhostMath.blockDifferences(original: luma, recompressed: recompressed, blockSize: blockSize)
            for block in 0..<min(differences.count, curves.count) {
                curves[block][index] = differences[block]
            }
        }

        let measured = curves.map { ($0.max() ?? 0) >= minimumMeasurableDifference }
        let ghostQualities = curves.indices.map { block in
            measured[block] ? JPEGGhostMath.ghostQuality(of: curves[block], qualities: qualities) : nil
        }
        let measuredCount = measured.filter { $0 }.count
        let withGhost = ghostQualities.compactMap { $0 }
        let historyPresent = measuredCount > 0 && Double(withGhost.count) >= minimumHistoryFraction * Double(measuredCount)
        let dominant = historyPresent ? JPEGGhostMath.dominantQuality(withGhost) : nil

        let blocks = curves.indices.map { block -> JPEGGhostBlock in
            let region = Region(x: (block % columns) * blockSize, y: (block / columns) * blockSize, width: blockSize, height: blockSize)
            guard let dominant, let quality = ghostQualities[block] else {
                return JPEGGhostBlock(region: region, status: .unreliable, ghostQuality: ghostQualities[block])
            }
            let status: JPEGGhostBlock.Status = abs(quality - dominant) >= disagreementThreshold ? .inconsistent : .consistent
            return JPEGGhostBlock(region: region, status: status, ghostQuality: quality)
        }

        return JPEGGhostMap(columns: columns, rows: rows, blocks: blocks, qualities: qualities, measuredBlockCount: measuredCount, dominantQuality: dominant)
    }

    /// `buffer` as a single-channel luminance buffer (the buffer itself if it
    /// already has one channel).
    static func luminance(of buffer: PixelBuffer) -> PixelBuffer? {
        guard buffer.channels > 1 else { return buffer }
        var pixels = [UInt8](repeating: 0, count: buffer.width * buffer.height)
        for y in 0..<buffer.height {
            for x in 0..<buffer.width {
                pixels[y * buffer.width + x] = buffer.luma(x: x, y: y)
            }
        }
        return try? PixelBuffer(width: buffer.width, height: buffer.height, channels: 1, pixels: pixels)
    }
}
