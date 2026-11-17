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

        let blockLuma = lumaPlane(buffer, region: block)
        guard clippedFraction(blockLuma.values) <= maximumClippedFraction else { return nil }
        let meanLuma = blockLuma.values.reduce(0, +) / Double(blockLuma.values.count)

        let x0 = max(0, block.x - 1)
        let y0 = max(0, block.y - 1)
        let x1 = min(buffer.width, block.x + block.width + 1)
        let y1 = min(buffer.height, block.y + block.height + 1)
        let bordered = lumaPlane(buffer, region: Region(x: x0, y: y0, width: x1 - x0, height: y1 - y0))
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

    /// Fraction of `values` at or within 2 gray levels of 0 or 255. An empty
    /// list counts as fully clipped.
    static func clippedFraction(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 1 }
        let clipped = values.filter { $0 <= 2.5 || $0 >= 252.5 }.count
        return Double(clipped) / Double(values.count)
    }
}
