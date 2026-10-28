import Foundation
import ImageDecoding

/// Detects localized editing by re-compressing an image at several JPEG
/// quality levels and measuring how consistently each region's error
/// responds across all of them.
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
/// A single recompression quality is a trade-off, and there's no value
/// that's "correct" for every image. Quantize more aggressively (lower
/// quality) and the recompression pass gets louder everywhere — genuine
/// edits stand out more against the noise, but so does ordinary image
/// content like sharp edges and fine texture, which pushes up false
/// positives. Go the other way and near-lossless quantization leaves
/// untouched regions barely moving, but a subtle edit's error signature
/// can shrink below `errorThreshold` and slip past unnoticed. Rather than
/// betting everything on one arbitrarily-chosen quality, this analyzer
/// recompresses at every quality in `elaQualityLevels` (default
/// `[70, 80, 90]`, mirroring the range of "save for web" exports most
/// photo editors default to) and combines the results: see `combine`'s
/// doc comment for how, and why a region that's only hot at one quality
/// level is treated as much weaker evidence than one that's hot at every
/// level configured.
public struct ELAAnalyzer: Analyzer {
    public let identifier = "ela"
    public let displayName = "Error Level Analysis"

    /// Used in place of `elaQualityLevels` when config supplies an empty
    /// list -- e.g. a hand-edited `forensiclens.yaml` with `[]` -- so ELA
    /// still has something to scan rather than doing no work at all.
    static let defaultQualityLevels = [70, 80, 90]

    public init() {}

    public func analyze(_ image: ImageData, config: ForensicLensConfig) throws -> AnalyzerFinding {
        guard let buffer = image.pixels else {
            throw AnalyzerError.unsupportedInput("ELA requires decoded pixel data, but this image has none (its format's pixel decoder is a documented stub -- see ImageDecoder).")
        }

        let qualityLevels = Self.sanitizedQualityLevels(config.ela.elaQualityLevels)
        let threshold = config.ela.errorThreshold

        // One recompression + diff pass per configured quality level. This
        // is the N-times-the-work trade-off documented in the requirements
        // for this feature: no extra parallelism is added here since
        // batch mode already parallelizes across whole images.
        let perLevelMaps = qualityLevels.map { quality -> [Double] in
            let recompressed = JPEGRecompressionSimulator.recompress(buffer, quality: quality)
            return Self.errorMap(original: buffer, recompressed: recompressed)
        }

        let (weightedErrorMap, agreementMap) = Self.combine(perLevelMaps, threshold: threshold)

        let reportingCellSize = 16
        let cells = Self.aggregate(weightedErrorMap, agreementMap, width: buffer.width, height: buffer.height, cellSize: reportingCellSize)

        let hotCells = cells.filter { $0.meanError >= threshold }
        let totalArea = cells.reduce(0) { $0 + $1.pixelCount }
        let hotArea = hotCells.reduce(0) { $0 + $1.pixelCount }
        let hotFraction = totalArea > 0 ? Double(hotArea) / Double(totalArea) : 0

        let meanError = weightedErrorMap.isEmpty ? 0 : weightedErrorMap.reduce(0, +) / Double(weightedErrorMap.count)
        let maxCellError = hotCells.map(\.meanError).max() ?? cells.map(\.meanError).max() ?? 0

        let coverageFraction = max(config.ela.flaggedRegionFraction, 0.0001)
        let coverageScore = min(60, (hotFraction / coverageFraction) * 60)
        let intensityScore = min(40, (maxCellError / max(threshold * 2, 1)) * 40)
        let score = coverageScore + intensityScore

        let levelCount = qualityLevels.count
        let levelsDescription = qualityLevels.map(String.init).joined(separator: ", ")

        var indicators: [Indicator] = []
        if !hotCells.isEmpty {
            let percent = String(format: "%.1f", hotFraction * 100)
            indicators.append(Indicator(
                message: "\(percent)% of the image falls inside \(hotCells.count) region(s) with cross-quality-consistent recompression error at or above \(String(format: "%.1f", threshold)), scanned at quality levels \(levelsDescription) (expected background level for an untouched image is well below this).",
                weight: coverageScore,
                regions: hotCells.map(\.region)
            ))

            for cell in hotCells.sorted(by: { $0.meanError > $1.meanError }).prefix(5) {
                let agreement = Int(cell.meanAgreementLevels.rounded())
                indicators.append(Indicator(
                    message: "Region (\(cell.x),\(cell.y))-(\(cell.x + cell.width),\(cell.y + cell.height)) was flagged at \(agreement) of \(levelCount) quality levels, with a consistency-weighted error level of \(String(format: "%.1f", cell.meanError)), notably higher than the image average of \(String(format: "%.1f", meanError)).",
                    weight: min(40, cell.meanError / max(threshold, 1) * 10),
                    regions: [cell.region]
                ))
            }
        }

        let summary: String
        if hotCells.isEmpty {
            summary = "No cross-quality-consistent error-level anomalies detected across quality levels \(levelsDescription) (mean \(String(format: "%.1f", meanError)))."
        } else {
            summary = "\(hotCells.count) region(s) show error levels inconsistent with a single uniform compression history, consistently across quality levels \(levelsDescription)."
        }

        return AnalyzerFinding(analyzerID: identifier, score: score, summary: summary, indicators: indicators)
    }

    /// Clamps each configured quality to the valid 1...100 range, or falls
    /// back to `defaultQualityLevels` entirely if the list is empty (e.g.
    /// an unset or emptied `elaQualityLevels` in config). This is the one
    /// place invalid config is handled rather than crashing further down
    /// in `JPEGRecompressionSimulator`.
    static func sanitizedQualityLevels(_ levels: [Int]) -> [Int] {
        guard !levels.isEmpty else { return defaultQualityLevels }
        return levels.map { max(1, min(100, $0)) }
    }

    /// Combines the per-quality-level error maps produced by `errorMap`
    /// into a single consistency-weighted map, plus a parallel count of
    /// how many quality levels flagged each pixel as an outlier.
    ///
    /// The naive way to combine several quality levels would be to just
    /// take the max error seen at any level, but that's exactly wrong for
    /// telling genuine tampering apart from single-level noise: ordinary
    /// sharp edges and fine texture can spike the error at *one*
    /// arbitrarily-chosen quality level, wherever that level's
    /// quantization step happens to land badly, without meaning anything
    /// about tampering. A pasted, differently-compressed region behaves
    /// differently: its compression history genuinely differs from the
    /// rest of the image, so it stands out at every quality level tried,
    /// not just one.
    ///
    /// So each pixel's combined error here is `maxError * agreementFraction`,
    /// where `agreementFraction` is the share of `perLevelMaps` at which
    /// that pixel's error already independently crossed `threshold`. A
    /// pixel that only spikes at one quality level out of three gets its
    /// error pulled down to a third of its raw magnitude -- likely back
    /// under `threshold`, and filtered out downstream -- while a pixel
    /// that spikes at every configured level keeps its full magnitude.
    /// This is what makes the analyzer's score driven primarily by
    /// *cross-level consistency* rather than by whichever single level
    /// happened to be noisiest, per this feature's design requirement.
    static func combine(_ perLevelMaps: [[Double]], threshold: Double) -> (weighted: [Double], agreementCount: [Int]) {
        guard let pixelCount = perLevelMaps.first?.count, pixelCount > 0, !perLevelMaps.isEmpty else {
            return ([], [])
        }
        let levelCount = perLevelMaps.count
        var weighted = [Double](repeating: 0, count: pixelCount)
        var agreementCount = [Int](repeating: 0, count: pixelCount)

        for i in 0..<pixelCount {
            var maxError = 0.0
            var hotLevels = 0
            for levelMap in perLevelMaps {
                let error = levelMap[i]
                if error > maxError { maxError = error }
                if error >= threshold { hotLevels += 1 }
            }
            agreementCount[i] = hotLevels
            weighted[i] = maxError * (Double(hotLevels) / Double(levelCount))
        }
        return (weighted, agreementCount)
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
        /// Mean consistency-weighted error (see `combine`) across this
        /// cell's pixels. Drives both the hot/not-hot filter and scoring.
        let meanError: Double
        /// Mean, across this cell's pixels, of how many configured quality
        /// levels independently flagged that pixel as an outlier. Purely
        /// descriptive -- used for the "flagged at X of N quality levels"
        /// reporting text, not for scoring.
        let meanAgreementLevels: Double
        let pixelCount: Int

        var region: Region {
            Region(x: x, y: y, width: width, height: height)
        }
    }

    private static func aggregate(_ errorMap: [Double], _ agreementMap: [Int], width: Int, height: Int, cellSize: Int) -> [ErrorCell] {
        guard width > 0, height > 0, !errorMap.isEmpty else { return [] }
        var cells: [ErrorCell] = []
        var cy = 0
        while cy < height {
            let cellHeight = min(cellSize, height - cy)
            var cx = 0
            while cx < width {
                let cellWidth = min(cellSize, width - cx)
                var sum = 0.0
                var agreementSum = 0
                for y in cy..<(cy + cellHeight) {
                    let rowBase = y * width
                    for x in cx..<(cx + cellWidth) {
                        sum += errorMap[rowBase + x]
                        agreementSum += agreementMap[rowBase + x]
                    }
                }
                let count = cellWidth * cellHeight
                cells.append(ErrorCell(
                    x: cx, y: cy, width: cellWidth, height: cellHeight,
                    meanError: sum / Double(count),
                    meanAgreementLevels: Double(agreementSum) / Double(count),
                    pixelCount: count
                ))
                cx += cellSize
            }
            cy += cellSize
        }
        return cells
    }
}
