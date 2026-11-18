import ImageDecoding

/// Walks an image block by block, measures each block's noise level, and
/// compares every block with the image's own typical level.
///
/// Each block's luma is read straight from the `PixelBuffer` with a
/// one-pixel border (where the image has one), so the high-pass residual
/// covers the whole block and memory stays at one block-sized plane at a
/// time, whatever the image size. The noise measure (`NoiseVariance`) and
/// the comparison rules (`NoiseDeviation`) live in their own types; this
/// one only decides which pixels make up a block and puts the results
/// together.
enum NoiseLevelEstimation {
    /// A block whose luma is more than this fraction clipped (at or within
    /// 2 levels of 0 or 255) isn't measured: a saturated or crushed sensor
    /// site records no noise, so such a block would always look smooth.
    static let maximumClippedFraction = 0.5

    /// Median block noise level, in gray levels, below which an image is
    /// treated as carrying no measurable noise (as `PRNUAnalyzer` does).
    /// Well under the ~0.29 gray levels that 8-bit rounding alone leaves on
    /// non-flat content, so only uniform-color, posterized, or synthetic
    /// images fall below it.
    static let minimumMeasurableNoise = 0.05

    /// Builds the noise-level map of `buffer` over non-overlapping
    /// `blockSize` x `blockSize` blocks. Partial blocks at the right and
    /// bottom edges are left out. Every measured block is compared with the
    /// median of all of them (`NoiseBaseline`), using `NoiseDeviation`'s
    /// cutoffs; flagged blocks are checked against the exposure model.
    /// An image too small for one block, or with no measurable noise, gives
    /// a map in which no block is judged.
    static func map(_ buffer: PixelBuffer, blockSize: Int, smoothThreshold: Double, noisyThreshold: Double) -> NoiseLevelMap {
        let columns = blockSize > 0 ? buffer.width / blockSize : 0
        let rows = blockSize > 0 ? buffer.height / blockSize : 0
        guard columns > 0, rows > 0 else {
            return NoiseLevelMap(columns: 0, rows: 0, blocks: [], typicalSigma: 0, typicalLuma: 0)
        }

        var regions: [Region] = []
        var measurements: [Measurement?] = []
        regions.reserveCapacity(columns * rows)
        measurements.reserveCapacity(columns * rows)
        for row in 0..<rows {
            for column in 0..<columns {
                let region = Region(x: column * blockSize, y: row * blockSize, width: blockSize, height: blockSize)
                regions.append(region)
                measurements.append(measure(buffer, block: region))
            }
        }

        let measured = measurements.compactMap { $0 }
        let typicalLuma = PRNUCorrelation.median(measured.map(\.meanLuma)) ?? 0
        let baseline = NoiseBaseline.of(measured.map(\.sigma))
        let typicalSigma = baseline?.medianSigma ?? 0

        // Without measurable noise there's nothing to compare against: every
        // measured block keeps its sigma, but none is judged.
        guard let baseline, typicalSigma >= minimumMeasurableNoise else {
            let blocks = zip(regions, measurements).map { region, measurement in
                NoiseBlockLevel(region: region, status: .unreliable, sigma: measurement?.sigma, ratio: nil, meanLuma: measurement?.meanLuma, exposureExplained: false)
            }
            return NoiseLevelMap(columns: columns, rows: rows, blocks: blocks, typicalSigma: typicalSigma, typicalLuma: typicalLuma)
        }

        let cutoffs = NoiseDeviation.cutoffs(for: baseline, smoothThreshold: smoothThreshold, noisyThreshold: noisyThreshold)
        let blocks = zip(regions, measurements).map { region, measurement -> NoiseBlockLevel in
            guard let measurement else {
                return NoiseBlockLevel(region: region, status: .unreliable, sigma: nil, ratio: nil, meanLuma: nil, exposureExplained: false)
            }
            let ratio = baseline.ratio(of: measurement.sigma)
            let direction = NoiseDeviation.classify(ratio: ratio, cutoffs: cutoffs)
            let status: NoiseBlockLevel.Status
            switch direction {
            case .tooSmooth: status = .tooSmooth
            case .tooNoisy: status = .tooNoisy
            case nil: status = .consistent
            }
            let explained = direction.map {
                NoiseDeviation.exposureExplained(ratio: ratio, direction: $0, blockLuma: measurement.meanLuma, typicalLuma: typicalLuma)
            } ?? false
            return NoiseBlockLevel(region: region, status: status, sigma: measurement.sigma, ratio: ratio, meanLuma: measurement.meanLuma, exposureExplained: explained)
        }
        return NoiseLevelMap(columns: columns, rows: rows, blocks: blocks, typicalSigma: typicalSigma, typicalLuma: typicalLuma,
                             smoothCutoff: cutoffs.lower, noisyCutoff: cutoffs.upper)
    }

    /// One block's measurement.
    struct Measurement: Sendable, Equatable {
        /// Robust noise standard deviation, in gray levels.
        let sigma: Double
        /// Mean luma over the block, 0...255.
        let meanLuma: Double
    }

    /// `block`'s noise level and brightness, or `nil` if the block is
    /// mostly clipped, lies outside the buffer, or is too small to hold a
    /// residual.
    static func measure(_ buffer: PixelBuffer, block: Region) -> Measurement? {
        guard block.width > 0, block.height > 0, block.x >= 0, block.y >= 0,
              block.x + block.width <= buffer.width, block.y + block.height <= buffer.height
        else { return nil }

        // The block plus its one-pixel border, read once: the border feeds
        // the residual, the interior gives brightness and clipping.
        let x0 = max(0, block.x - 1)
        let y0 = max(0, block.y - 1)
        let x1 = min(buffer.width, block.x + block.width + 1)
        let y1 = min(buffer.height, block.y + block.height + 1)
        let bordered = lumaPlane(buffer, region: Region(x: x0, y: y0, width: x1 - x0, height: y1 - y0))

        var sum = 0.0
        var clipped = 0
        for row in (block.y - y0)..<(block.y - y0 + block.height) {
            let start = row * bordered.width + (block.x - x0)
            for value in bordered.values[start..<(start + block.width)] {
                sum += value
                if value <= 2.5 || value >= 252.5 { clipped += 1 }
            }
        }
        let pixelCount = block.width * block.height
        guard Double(clipped) / Double(pixelCount) <= maximumClippedFraction else { return nil }
        let meanLuma = sum / Double(pixelCount)

        guard let sigma = NoiseVariance.robustSigma(of: NoiseResidual.highPass(bordered).values) else { return nil }
        return Measurement(sigma: sigma, meanLuma: meanLuma)
    }

    /// Unrounded Rec. 601 luma of `region` (which must lie inside the
    /// buffer), the same formula as `PRNUPlane.luminance`, read for one
    /// region instead of the whole image.
    static func lumaPlane(_ buffer: PixelBuffer, region: Region) -> PRNUPlane {
        guard region.width > 0, region.height > 0, region.x >= 0, region.y >= 0,
              region.x + region.width <= buffer.width, region.y + region.height <= buffer.height
        else { return PRNUPlane(width: 0, height: 0) }

        let pixels = buffer.pixels
        var values = [Double](repeating: 0, count: region.width * region.height)
        for row in 0..<region.height {
            for col in 0..<region.width {
                let base = buffer.offset(x: region.x + col, y: region.y + row)
                values[row * region.width + col] = buffer.channels >= 3
                    ? 0.299 * Double(pixels[base]) + 0.587 * Double(pixels[base + 1]) + 0.114 * Double(pixels[base + 2])
                    : Double(pixels[base])
            }
        }
        return PRNUPlane(width: region.width, height: region.height, values: values)
    }
}
