import Foundation

/// Compares an EXIF thumbnail with the main image, both as luminance planes:
/// resampling, trimming the thumbnail's letterbox bars, comparing aspect
/// ratios, and the similarity score itself. Kept free of EXIF parsing and
/// JPEG decoding so every piece can be tested on small synthetic planes.
///
/// **Similarity metric.** Normalized cross-correlation (Pearson) of the two
/// luminance grids, once over the whole thumbnail and once per cell of a
/// 4x4 grid. The score is the lowest of these. NCC ignores brightness and
/// contrast offsets, so the thumbnail's own JPEG compression and a camera's
/// slightly different tone curve for previews don't count as differences.
/// The per-cell part is what makes it sensitive to local edits. Measured on
/// a 512x384 synthetic scene with a 64x48 thumbnail, a 128px region pasted
/// into the main image (6% of its area) only moved the *global* NCC from
/// 0.98 to 0.94, but dropped the edited cell to 0.11. A 64px edit (1.6%)
/// gave 0.47, and the unedited image's worst cell was 0.94. Edits much
/// smaller than one cell (a 32px edit is 4 thumbnail pixels) stay below what
/// any thumbnail-sized comparison can resolve. A perceptual hash was the
/// alternative. It's coarser (a few dozen bits for the whole image) and
/// says nothing about *where* the images differ, while the cell grid can
/// point at the region.
enum ThumbnailSimilarity {
    /// Grid size for the per-cell comparison.
    static let gridSize = 4

    /// A cell is compared only if at least one of the two images has this
    /// much luminance standard deviation in it. Featureless cells (sky, a
    /// wall) make NCC meaningless noise.
    static let minimumCellDeviation = 6.0

    /// Row or column statistics a letterbox bar must stay under: mean
    /// luminance at most `barMaximumMean`, standard deviation at most
    /// `barMaximumDeviation`. Bars are stored as JPEG too, and ringing from
    /// the content edge leaves them noisy: measured on synthetic 64x48 and
    /// 160x120 thumbnails at quality 60 to 75, bar rows had means of up to 4
    /// and deviations of up to 5.2, against 40+ for content rows.
    static let barMaximumMean = 20.0
    static let barMaximumDeviation = 8.0

    /// Area-average resampling (each output sample is the overlap-weighted
    /// mean of the input samples it covers). Works for both shrinking and
    /// enlarging; an empty plane or target gives an empty plane.
    static func resample(_ plane: PRNUPlane, toWidth width: Int, height: Int) -> PRNUPlane {
        guard plane.width > 0, plane.height > 0, width > 0, height > 0 else { return PRNUPlane(width: 0, height: 0) }
        if plane.width == width && plane.height == height { return plane }

        let scaleX = Double(plane.width) / Double(width)
        let scaleY = Double(plane.height) / Double(height)
        var output = [Double](repeating: 0, count: width * height)
        for ty in 0..<height {
            let y0 = Double(ty) * scaleY
            let y1 = Double(ty + 1) * scaleY
            for tx in 0..<width {
                let x0 = Double(tx) * scaleX
                let x1 = Double(tx + 1) * scaleX
                var sum = 0.0
                var weightSum = 0.0
                for sy in Int(y0)..<min(plane.height, Int(y1.rounded(.up))) {
                    let wy = min(y1, Double(sy + 1)) - max(y0, Double(sy))
                    guard wy > 0 else { continue }
                    for sx in Int(x0)..<min(plane.width, Int(x1.rounded(.up))) {
                        let wx = min(x1, Double(sx + 1)) - max(x0, Double(sx))
                        guard wx > 0 else { continue }
                        sum += plane.values[sy * plane.width + sx] * wx * wy
                        weightSum += wx * wy
                    }
                }
                output[ty * width + tx] = weightSum > 0 ? sum / weightSum : 0
            }
        }
        return PRNUPlane(width: width, height: height, values: output)
    }

    /// The thumbnail's content area with any black letterbox or pillarbox
    /// bars trimmed off. Some cameras store a fixed 160x120 (4:3) thumbnail
    /// even for 3:2 or 16:9 photos and fill the difference with black bars;
    /// those mustn't be read as content or as a reframed image. At most a
    /// quarter of each dimension is trimmed per side.
    static func contentRegion(of thumbnail: PRNUPlane) -> Region {
        let width = thumbnail.width
        let height = thumbnail.height
        func isBar(_ values: [Double]) -> Bool {
            guard !values.isEmpty else { return false }
            let mean = values.reduce(0, +) / Double(values.count)
            let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
            return mean <= barMaximumMean && variance.squareRoot() <= barMaximumDeviation
        }
        func row(_ y: Int) -> [Double] { Array(thumbnail.values[(y * width)..<((y + 1) * width)]) }
        func column(_ x: Int, from top: Int, to bottom: Int) -> [Double] { (top..<bottom).map { thumbnail.values[$0 * width + x] } }

        var top = 0
        var bottom = height
        while top < height / 4, isBar(row(top)) { top += 1 }
        while height - bottom < height / 4, bottom > top + 1, isBar(row(bottom - 1)) { bottom -= 1 }
        var left = 0
        var right = width
        while left < width / 4, isBar(column(left, from: top, to: bottom)) { left += 1 }
        while width - right < width / 4, right > left + 1, isBar(column(right - 1, from: top, to: bottom)) { right -= 1 }
        return Region(x: left, y: top, width: right - left, height: bottom - top)
    }

    /// `|ln(aspect A / aspect B)|`: 0 for identical aspect ratios, about
    /// 0.29 between 4:3 and 16:9. Symmetric, and independent of image size.
    static func aspectRatioDifference(width: Int, height: Int, otherWidth: Int, otherHeight: Int) -> Double {
        guard width > 0, height > 0, otherWidth > 0, otherHeight > 0 else { return .infinity }
        return abs(log((Double(width) / Double(height)) / (Double(otherWidth) / Double(otherHeight))))
    }

    /// The largest region of `region` with the aspect ratio
    /// `aspectWidth`:`aspectHeight`, centered: where a centered crop to the
    /// main image's shape would sit inside the thumbnail.
    static func centeredRegion(withAspect aspectWidth: Int, _ aspectHeight: Int, in region: Region) -> Region {
        guard aspectWidth > 0, aspectHeight > 0, region.width > 0, region.height > 0 else { return region }
        let target = Double(aspectWidth) / Double(aspectHeight)
        if Double(region.width) / Double(region.height) > target {
            let width = max(1, Int((Double(region.height) * target).rounded()))
            return Region(x: region.x + (region.width - width) / 2, y: region.y, width: width, height: region.height)
        }
        let height = max(1, Int((Double(region.width) / target).rounded()))
        return Region(x: region.x, y: region.y + (region.height - height) / 2, width: region.width, height: height)
    }

    /// The outcome of comparing two same-size luminance planes.
    struct Comparison: Equatable {
        /// NCC over the whole planes (`nil` if both are featureless).
        let global: Double?
        /// The lowest NCC among the compared cells (`nil` if none had detail).
        let worstCell: Double?
        /// The worst cell's area, in the compared planes' coordinates.
        let worstCellRegion: Region?
        let cellsCompared: Int

        /// The score the threshold applies to: the lower of `global` and
        /// `worstCell`.
        var similarity: Double {
            [global, worstCell].compactMap { $0 }.min() ?? 1
        }
    }

    /// Compares two planes of the same size (see this type's doc comment).
    /// `nil` if the sizes differ, or both planes are featureless everywhere
    /// so there's nothing to compare. If only one of a pair (the whole
    /// planes, or a cell) is featureless, that pair scores 0. Detail where
    /// the other image has none is a difference, as when an object was
    /// removed from the main image and the gap filled with flat color.
    static func compare(_ main: PRNUPlane, _ thumbnail: PRNUPlane) -> Comparison? {
        guard main.width == thumbnail.width, main.height == thumbnail.height, main.width > 0, main.height > 0 else { return nil }

        func deviation(_ values: [Double]) -> Double {
            let mean = values.reduce(0, +) / Double(values.count)
            return (values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)).squareRoot()
        }
        func correlation(_ a: [Double], _ b: [Double]) -> Double? {
            let deviationA = deviation(a)
            let deviationB = deviation(b)
            guard deviationA >= minimumCellDeviation || deviationB >= minimumCellDeviation else { return nil }
            return PRNUCorrelation.normalizedCrossCorrelation(a, b) ?? 0
        }

        let global = correlation(main.values, thumbnail.values)
        let grid = max(1, min(gridSize, main.width / 4, main.height / 4))
        var worst: Double?
        var worstRegion: Region?
        var compared = 0
        for cellY in 0..<grid {
            for cellX in 0..<grid {
                let region = Region(
                    x: cellX * main.width / grid,
                    y: cellY * main.height / grid,
                    width: (cellX + 1) * main.width / grid - cellX * main.width / grid,
                    height: (cellY + 1) * main.height / grid - cellY * main.height / grid
                )
                guard let value = correlation(main.cropped(to: region).values, thumbnail.cropped(to: region).values) else { continue }
                compared += 1
                if worst.map({ value < $0 }) ?? true {
                    worst = value
                    worstRegion = region
                }
            }
        }
        guard global != nil || worst != nil else { return nil }
        return Comparison(global: global, worstCell: worst, worstCellRegion: worstRegion, cellsCompared: compared)
    }
}
