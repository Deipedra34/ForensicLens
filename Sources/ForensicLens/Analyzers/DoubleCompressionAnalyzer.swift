import ImageDecoding

/// Detects whether a JPEG's pixel data carries the fingerprint of two
/// separate compression passes: an original save, then a re-save after the
/// image was opened, edited, and exported again.
///
/// Every lossy JPEG encode quantizes each 8x8 block's DCT coefficients --
/// rounds them to the nearest multiple of a per-frequency step size, which
/// is exactly what makes JPEG lossy in the first place. Do that once, and a
/// histogram of any one coefficient position across every block in the
/// image comes out smooth: a single broad hump, thinned out by rounding but
/// with no particular structure to it. Decompress that image, edit it, and
/// re-encode it at a second, generally different quality, and every one of
/// those coefficients gets quantized *again* -- to multiples of a second
/// step size that doesn't line up with the first. Because the two steps
/// don't share a common multiple in the general case, some final values end
/// up reachable from several different first-pass values while others
/// become reachable from almost none, so the once-smooth histogram grows a
/// periodic comb of peaks and near-empty valleys on top of its original
/// shape. That comb, not the presence of any single "suspicious" value, is
/// the signature this analyzer looks for -- it's a classic, well-studied
/// double-JPEG-compression tell, and it's essentially independent of what
/// ELA, EXIF analysis, and clone detection each look at, so it catches
/// edits that sail straight through all three of those.
///
/// This only has anything to measure on a JPEG-sourced image -- other
/// formats this package can decode (BMP, PPM/PGM) were never quantized in
/// 8x8 DCT blocks to begin with, so there's no compression-history artifact
/// here to look for, and this analyzer reports "not applicable" rather than
/// scoring them. The actual coefficient extraction, histogram, and
/// periodicity math live in `DCTPeriodicityAnalysis`; this type is just the
/// `Analyzer` glue and the offset search described below.
///
/// Cropping between the two compressions shifts the second pass's 8x8
/// block grid relative to pixel `(0, 0)` of the file being analyzed now, so
/// this doesn't just sample the grid anchored at `(0, 0)`. It tries a
/// reduced set of candidate pixel offsets (a coarse quarter of the 8x8 = 64
/// possible ones -- every second pixel along each axis -- rather than all
/// 64, which would multiply the cost of the whole scan for offsets that
/// tend to agree closely with a nearby one anyway) and reports whichever
/// offset's histogram shows the strongest periodicity, on the theory that
/// only an offset close to the real second-pass grid will show the comb at
/// full strength; a badly misaligned grid mixes coefficients from several
/// original blocks together and washes the pattern out.
public struct DoubleCompressionAnalyzer: Analyzer {
    public let identifier = "doublecompression"
    public let displayName = "Double JPEG Compression Detection"

    private static let blockSize = 8

    /// The candidate block-grid offsets tried per requirement: a reduced,
    /// practical subset of the 8x8 = 64 possible pixel offsets rather than
    /// every one of them, since a full sweep costs 64x a single-offset scan
    /// for comparatively little extra recall -- neighboring offsets tend to
    /// land on much the same blocks and thus much the same histogram.
    private static let candidateOffsets: [(x: Int, y: Int)] = {
        var offsets: [(x: Int, y: Int)] = []
        for y in stride(from: 0, to: blockSize, by: 2) {
            for x in stride(from: 0, to: blockSize, by: 2) {
                offsets.append((x: x, y: y))
            }
        }
        return offsets
    }()

    /// Below this many sampled blocks, a coefficient histogram is too
    /// sparse for its spectrum to mean anything -- a handful of blocks can
    /// look "periodic" purely by chance depending on exactly how they
    /// landed, regardless of the image's real compression history.
    private static let minimumBlockCount = 16

    public init() {}

    public func analyze(_ image: ImageData, config: ForensicLensConfig) throws -> AnalyzerFinding {
        guard image.format == .jpeg else {
            return AnalyzerFinding.clean(
                analyzerID: identifier,
                summary: "\(image.format?.rawValue.uppercased() ?? "This") format was never JPEG-compressed, so it has no DCT quantization history to analyze; not applicable."
            )
        }

        guard let buffer = image.pixels else {
            throw AnalyzerError.unsupportedInput("Double-compression analysis requires decoded pixel data, but this image has none (its format's pixel decoder is a documented stub -- see ImageDecoder).")
        }

        let settings = config.doubleCompression
        let row = max(0, min(Self.blockSize - 1, settings.acCoefficientRow))
        let col = max(0, min(Self.blockSize - 1, settings.acCoefficientColumn))

        var bestStrength = 0.0
        var bestOffset: (x: Int, y: Int) = (0, 0)
        var sampledAnyOffset = false

        for offset in Self.candidateOffsets {
            let values = DCTPeriodicityAnalysis.blockCoefficients(in: buffer, row: row, col: col, offsetX: offset.x, offsetY: offset.y)
            guard values.count >= Self.minimumBlockCount else { continue }
            sampledAnyOffset = true

            let (bins, _) = DCTPeriodicityAnalysis.histogram(of: values)
            let strength = DCTPeriodicityAnalysis.periodicityStrength(of: bins)
            if strength > bestStrength {
                bestStrength = strength
                bestOffset = offset
            }
        }

        let coefficientLabel = "(\(row),\(col))"

        guard sampledAnyOffset else {
            return AnalyzerFinding.clean(
                analyzerID: identifier,
                summary: "Image is too small to sample enough 8x8 blocks at coefficient \(coefficientLabel) for double-compression analysis."
            )
        }

        let threshold = settings.periodicityThreshold

        guard bestStrength >= threshold else {
            return AnalyzerFinding.clean(
                analyzerID: identifier,
                summary: "No periodic pattern found in the histogram of DCT coefficient \(coefficientLabel) (peak periodicity \(String(format: "%.2f", bestStrength)), below threshold \(String(format: "%.2f", threshold))); consistent with a single compression pass."
            )
        }

        let normalizedExcess = min(1.0, (bestStrength - threshold) / max(0.0001, 1.0 - threshold))
        let score = normalizedExcess * 100

        // Double compression is a whole-image property, not a localized
        // one: the evidence is the histogram pooled over every sampled
        // block. So the region reported is the full area that histogram was
        // sampled from -- every complete 8x8 block on the winning offset's
        // grid -- rather than any one block.
        let sampledRegion = Region(
            x: bestOffset.x,
            y: bestOffset.y,
            width: (buffer.width - bestOffset.x) / Self.blockSize * Self.blockSize,
            height: (buffer.height - bestOffset.y) / Self.blockSize * Self.blockSize
        )

        let indicator = Indicator(
            message: "Histogram of DCT coefficient \(coefficientLabel), sampled on an 8x8 block grid offset by (\(bestOffset.x),\(bestOffset.y)) px, shows a periodic double-peak pattern with periodicity strength \(String(format: "%.2f", bestStrength)) (threshold \(String(format: "%.2f", threshold))) -- periodic DCT coefficient pattern detected; image was likely re-compressed after editing.",
            weight: score,
            regions: [sampledRegion]
        )

        let summary = "Periodic DCT coefficient pattern detected at coefficient \(coefficientLabel); this image's pixel data is consistent with having been JPEG-compressed twice."

        return AnalyzerFinding(analyzerID: identifier, score: score, summary: summary, indicators: [indicator])
    }
}
