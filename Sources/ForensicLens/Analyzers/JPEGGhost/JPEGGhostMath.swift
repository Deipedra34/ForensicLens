import ImageDecoding

/// The small, separately testable pieces of JPEG ghost detection: block
/// difference maps, finding a block's ghost quality in its difference
/// curve, and the image's dominant quality. The quality sweep that feeds
/// them lives in `JPEGGhostAnalysis`.
///
/// Background (Farid, "Exposing Digital Forgeries From JPEG Ghosts", 2009):
/// re-saving a JPEG at the quality it was last saved at changes almost
/// nothing, because its DCT coefficients are already multiples of that
/// quality's quantization steps. Plotting a region's difference after
/// re-compression against the re-compression quality therefore gives a
/// curve that, besides trending down toward quality 100, dips at every
/// quality the region was saved at. Those dips are its "ghosts".
enum JPEGGhostMath {
    /// How deep a dip must be to count as a ghost: its difference must be
    /// at most `1 - minimumDipDepth` times the lower of its neighbors'.
    /// Measured dips are near-total at the last save quality and roughly
    /// 60% deep for an earlier one; ripples in a smooth, never-compressed
    /// curve are far shallower.
    static let minimumDipDepth = 0.3

    /// The quality levels to sweep: `minimum` through `maximum` in `step`
    /// increments, clamped to 1...100 (swapped if given in reverse), always
    /// ending at `maximum`. A non-positive step is treated as 1.
    static func qualityLevels(minimum: Int, maximum: Int, step: Int) -> [Int] {
        let low = max(1, min(100, min(minimum, maximum)))
        let high = max(1, min(100, max(minimum, maximum)))
        var levels = Array(stride(from: low, through: high, by: max(1, step)))
        if levels.last != high { levels.append(high) }
        return levels
    }

    /// Mean squared difference between `original` and `recompressed` (same
    /// size, single channel) over each complete `blockSize` x `blockSize`
    /// block, row-major. Partial blocks at the right and bottom edges are
    /// left out. Empty if the buffers don't match.
    static func blockDifferences(original: PixelBuffer, recompressed: PixelBuffer, blockSize: Int) -> [Double] {
        guard blockSize > 0,
              original.width == recompressed.width, original.height == recompressed.height,
              original.channels == 1, recompressed.channels == 1
        else { return [] }

        let columns = original.width / blockSize
        let rows = original.height / blockSize
        var sums = [Double](repeating: 0, count: columns * rows)
        for y in 0..<(rows * blockSize) {
            let rowStart = y * original.width
            let blockRow = (y / blockSize) * columns
            for x in 0..<(columns * blockSize) {
                let difference = Double(original.pixels[rowStart + x]) - Double(recompressed.pixels[rowStart + x])
                sums[blockRow + x / blockSize] += difference * difference
            }
        }
        let area = Double(blockSize * blockSize)
        return sums.map { $0 / area }
    }

    /// Every ghost in a difference `curve` (one value per entry of
    /// `qualities`, ascending): each quality whose difference is a local
    /// minimum at least `minimumDipDepth` deep. The lowest quality counts
    /// if it's already below its one neighbor. The highest never does,
    /// since any image's curve keeps falling toward lossless there,
    /// compressed or not.
    static func ghosts(in curve: [Double], qualities: [Int]) -> [Int] {
        guard curve.count == qualities.count, curve.count >= 2 else { return [] }
        var found: [Int] = []
        for i in 0..<(curve.count - 1) {
            let right = curve[i + 1]
            let neighbor = i > 0 ? min(curve[i - 1], right) : right
            if curve[i] < neighbor && curve[i] <= (1 - minimumDipDepth) * neighbor {
                found.append(qualities[i])
            }
        }
        return found
    }

    /// A block's ghost quality: its lowest-quality ghost, or `nil` if its
    /// curve has none.
    ///
    /// Why the lowest rather than the deepest: re-saving the finished image
    /// leaves a near-total dip at its final quality in *every* block, a
    /// spliced one included. A region's own earlier compression shows up as
    /// an additional dip, usually at a lower quality, and that's what tells
    /// it apart. In an untouched JPEG every block's lowest ghost is the
    /// same quality.
    static func ghostQuality(of curve: [Double], qualities: [Int]) -> Int? {
        ghosts(in: curve, qualities: qualities).first
    }

    /// The image's dominant ghost quality: the most common value in
    /// `blockQualities`, with ties going to the lower quality. `nil` if
    /// there are none.
    static func dominantQuality(_ blockQualities: [Int]) -> Int? {
        var counts: [Int: Int] = [:]
        for quality in blockQualities { counts[quality, default: 0] += 1 }
        return counts.max { a, b in a.value != b.value ? a.value < b.value : a.key > b.key }?.key
    }
}
