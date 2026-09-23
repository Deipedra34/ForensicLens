import Foundation
import ImageDecoding

/// Detects copy-pasted ("copy-move") regions within a single image.
///
/// Copy-move forgery — cloning a patch of an image over another part of the
/// same image to duplicate or erase something — is invisible to EXIF
/// analysis, since the file is still a single, internally consistent
/// export. It's often invisible to ELA too, because the pasted patch
/// shares the exact same compression history as everything else; it came
/// from the same image, after all. What actually gives it away is that two
/// regions of the picture are near-identical in a way real photographed
/// scenes essentially never are.
///
/// The approach here is the classic one: sweep the image with a sliding
/// `blockSize` x `blockSize` window, stepped by `blockStride`. Reduce each
/// block to a small feature vector (a coarse grid of average brightness
/// values) and compare it against every other block. A pair whose feature
/// vectors are close together, and whose positions are far enough apart to
/// not just be the same patch of sky overlapping itself, gets reported as
/// a candidate clone. Blocks with near-zero pixel variance — flat sky, a
/// solid wall, a studio background — get skipped before any comparison
/// even happens, because without that filter a smooth gradient would
/// "match" itself thousands of times over and bury any real finding under
/// noise.
///
/// `blockSize` is the main trade-off to know about: it trades detection
/// granularity against both compute cost and robustness. A small block
/// (say 8px) can pick out a small cloned region and pinpoint it precisely,
/// but it also has less content to fingerprint, so unrelated blocks start
/// looking alike just by chance — more false positives — and there are a
/// lot more of them to compare pairwise, which costs quadratic time. A
/// bigger block (say 32px) is fast and confident when it matches, but a
/// clone smaller than the block, or one shifted by only a few pixels from
/// an otherwise-identical neighbor, can slip right past it. `blockStride`
/// plays a similar role on a different axis: a smaller stride overlaps
/// blocks more and catches clones the block grid would otherwise straddle,
/// at the cost of comparing a lot more blocks.
public struct CloneDetectionAnalyzer: Analyzer {
    public let identifier = "clone"
    public let displayName = "Copy-Move (Clone) Detection"

    /// Side length of the coarse grid each block is reduced to before
    /// comparison. 4x4 keeps the feature vector cheap to compare while
    /// still capturing enough of a block's brightness layout to tell
    /// genuinely different content apart.
    private static let featureGridSize = 4

    /// Minimum number of matched block pairs before clone detection treats
    /// coverage as worth reporting rather than a single coincidental match.
    private static let minimumReportablePairs = 1

    public init() {}

    public func analyze(_ image: ImageData, config: ForensicLensConfig) throws -> AnalyzerFinding {
        guard let buffer = image.pixels else {
            throw AnalyzerError.unsupportedInput("Clone detection requires decoded pixel data, but this image has none.")
        }

        let settings = config.cloneDetection
        let blockSize = max(4, settings.blockSize)
        let stride = max(1, settings.blockStride)

        guard buffer.width >= blockSize, buffer.height >= blockSize else {
            return AnalyzerFinding.clean(analyzerID: identifier, summary: "Image is smaller than one comparison block; nothing to compare.")
        }

        let candidates = Self.candidateBlocks(buffer, blockSize: blockSize, stride: stride, minimumVariance: settings.minimumBlockVariance)
        guard candidates.count >= 2 else {
            return AnalyzerFinding.clean(analyzerID: identifier, summary: "No non-uniform regions found to compare; image may be flat or too small.")
        }

        let matches = Self.findMatches(candidates, similarityThreshold: settings.similarityThreshold, minimumDistance: settings.minimumBlockDistance)
        return Self.makeFinding(analyzerID: identifier, matches: matches, imageWidth: buffer.width, imageHeight: buffer.height, settings: settings)
    }

    /// Builds the final `AnalyzerFinding` from a completed set of block
    /// matches -- the exact same scoring and indicator-building logic
    /// `analyze` uses for a single, untiled image, factored out so
    /// `TiledCloneDetection` can reuse it verbatim for `matches` gathered
    /// globally across every tile (passing the *full* image's dimensions,
    /// not any one tile's). Keeping one scoring implementation shared by
    /// both paths is what makes a tiled and an untiled clone detection
    /// score numerically identical (not just "close") whenever the same
    /// matches are found, rather than two scoring formulas that could
    /// quietly drift apart.
    static func makeFinding(analyzerID: String, matches: [Match], imageWidth: Int, imageHeight: Int, settings: ForensicLensConfig.CloneDetectionConfig) -> AnalyzerFinding {
        let blockSize = max(4, settings.blockSize)
        guard matches.count >= minimumReportablePairs else {
            return AnalyzerFinding.clean(analyzerID: analyzerID, summary: "No duplicated regions detected.")
        }

        let uniqueBlocks = Set(matches.flatMap { [$0.a, $0.b] })
        let imageArea = Double(imageWidth * imageHeight)
        let coverageFraction = imageArea > 0 ? min(1.0, Double(uniqueBlocks.count * blockSize * blockSize) / imageArea) : 0

        let areaScore = min(80, (coverageFraction / 0.02) * 80)
        let countScore = min(20, Double(matches.count))
        let score = areaScore + countScore

        func blockRegion(_ position: BlockPosition) -> Region {
            Region(x: position.x, y: position.y, width: blockSize, height: blockSize)
        }

        // Sorted so the summary indicator's region list (and therefore
        // JSON output) is deterministic rather than following `Set` order.
        let matchedRegions = uniqueBlocks
            .sorted { ($0.y, $0.x) < ($1.y, $1.x) }
            .map(blockRegion)

        let percent = String(format: "%.1f", coverageFraction * 100)
        var indicators = [Indicator(
            message: "\(matches.count) matching block pair(s) found, covering approximately \(percent)% of the image area.",
            weight: areaScore,
            regions: matchedRegions
        )]

        for match in matches.sorted(by: { $0.distance < $1.distance }).prefix(5) {
            indicators.append(Indicator(
                message: "Block at (\(match.a.x),\(match.a.y)) closely matches block at (\(match.b.x),\(match.b.y)) (feature distance \(String(format: "%.2f", match.distance)), \(match.spatialDistance) px apart).",
                weight: min(20, max(0, settings.similarityThreshold - match.distance) * 4),
                regions: [blockRegion(match.a), blockRegion(match.b)]
            ))
        }

        let summary = "\(matches.count) duplicated region pair(s) found, suggesting copy-move editing."
        return AnalyzerFinding(analyzerID: analyzerID, score: score, summary: summary, indicators: indicators)
    }

    // MARK: - Block extraction

    /// A block's top-left corner, in the coordinate space it was scanned
    /// in. Not `private`: `TiledCloneDetection` scans each tile in that
    /// tile's own local coordinates and then translates every
    /// `BlockPosition` it keeps into image-global coordinates itself (see
    /// that type's doc comment), so this type crosses that module
    /// boundary too.
    struct BlockPosition: Hashable, Sendable {
        let x: Int
        let y: Int
    }

    /// A candidate block and its comparison fingerprint. Not `private` for
    /// the same reason as `BlockPosition`: `TiledCloneDetection` builds one
    /// global list of these, pooled across every tile, before calling
    /// `findMatches` a single time over the whole image -- see that type's
    /// doc comment for why the pooling has to happen before matching, not
    /// after.
    struct Candidate: Sendable {
        let position: BlockPosition
        let feature: [Double]
    }

    /// A pair of candidate blocks whose feature vectors were close enough,
    /// and whose positions were far enough apart, to report as a possible
    /// copy-move. Not `private`, for the same cross-module reason as
    /// `BlockPosition`/`Candidate`.
    struct Match: Sendable {
        let a: BlockPosition
        let b: BlockPosition
        let distance: Double
        let spatialDistance: Int
    }

    /// Scans `buffer` for non-flat comparison blocks and returns their
    /// fingerprints. `buffer`'s own coordinate space is whatever the
    /// caller gave it -- global image coordinates for a single, untiled
    /// pass, or a tile-local space that `TiledCloneDetection` translates
    /// back to global coordinates itself. Not `private`, so the tiling
    /// layer can reuse this exact scanning logic per tile.
    static func candidateBlocks(_ buffer: PixelBuffer, blockSize: Int, stride: Int, minimumVariance: Double) -> [Candidate] {
        var candidates: [Candidate] = []
        var by = 0
        while by + blockSize <= buffer.height {
            var bx = 0
            while bx + blockSize <= buffer.width {
                let luma = lumaValues(buffer, x: bx, y: by, size: blockSize)
                let mean = luma.reduce(0, +) / Double(luma.count)
                let variance = luma.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(luma.count)
                if variance >= minimumVariance {
                    let feature = downsample(luma, size: blockSize, gridSize: featureGridSize)
                    candidates.append(Candidate(position: BlockPosition(x: bx, y: by), feature: feature))
                }
                bx += stride
            }
            by += stride
        }
        return candidates
    }

    private static func lumaValues(_ buffer: PixelBuffer, x: Int, y: Int, size: Int) -> [Double] {
        var values = [Double](repeating: 0, count: size * size)
        for row in 0..<size {
            for col in 0..<size {
                values[row * size + col] = Double(buffer.luma(x: x + col, y: y + row))
            }
        }
        return values
    }

    /// Reduces a `size` x `size` luma grid to a `gridSize` x `gridSize`
    /// vector of cell averages, used as the block's comparison fingerprint.
    private static func downsample(_ luma: [Double], size: Int, gridSize: Int) -> [Double] {
        var feature = [Double](repeating: 0, count: gridSize * gridSize)
        for gy in 0..<gridSize {
            let yStart = gy * size / gridSize
            let yEnd = max(yStart + 1, (gy + 1) * size / gridSize)
            for gx in 0..<gridSize {
                let xStart = gx * size / gridSize
                let xEnd = max(xStart + 1, (gx + 1) * size / gridSize)
                var sum = 0.0
                var count = 0
                for y in yStart..<yEnd {
                    for x in xStart..<xEnd {
                        sum += luma[y * size + x]
                        count += 1
                    }
                }
                feature[gy * gridSize + gx] = count > 0 ? sum / Double(count) : 0
            }
        }
        return feature
    }

    // MARK: - Matching

    /// Compares every candidate against every other candidate -- an O(n^2)
    /// pass over `candidates`. Not `private`: `TiledCloneDetection` calls
    /// this exactly once, over one global list of candidates pooled across
    /// every tile, rather than once per tile, which is what lets a clone
    /// whose source and copy landed in two different (possibly distant)
    /// tiles still be compared against each other and found. See that
    /// type's doc comment for the full reasoning.
    static func findMatches(_ candidates: [Candidate], similarityThreshold: Double, minimumDistance: Int) -> [Match] {
        var matches: [Match] = []
        for i in 0..<candidates.count {
            for j in (i + 1)..<candidates.count {
                let a = candidates[i]
                let b = candidates[j]

                let dx = a.position.x - b.position.x
                let dy = a.position.y - b.position.y
                let spatialDistanceSquared = dx * dx + dy * dy
                guard spatialDistanceSquared >= minimumDistance * minimumDistance else { continue }

                let distance = euclideanDistance(a.feature, b.feature)
                guard distance <= similarityThreshold else { continue }

                matches.append(Match(
                    a: a.position,
                    b: b.position,
                    distance: distance,
                    spatialDistance: Int(Double(spatialDistanceSquared).squareRoot().rounded())
                ))
            }
        }
        return matches
    }

    private static func euclideanDistance(_ a: [Double], _ b: [Double]) -> Double {
        var sum = 0.0
        for i in 0..<a.count {
            let diff = a[i] - b[i]
            sum += diff * diff
        }
        return sum.squareRoot()
    }
}
