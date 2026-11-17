import Foundation
import ImageDecoding
@testable import ForensicLens

/// Synthetic images for the noise-level consistency tests. Every value
/// comes from a fixed seed, so each test sees the same pixels on every run.
extension Fixtures {
    /// How one region of a `noiseLevelImage` was produced.
    enum NoiseRegionSource {
        /// The scene with noise of a different standard deviation.
        case noise(sigma: Double, seed: UInt64)
        /// The region as captured, then box-blurred with a
        /// `2 * radius + 1` window: what a smoothing brush, a denoiser, or
        /// a pasted-in soft region leaves behind.
        case blurred(radius: Int)
    }

    /// A grayscale (or, with `channels: 3`, equal-RGB) capture of the smooth
    /// `syntheticScene` with Gaussian noise of standard deviation `sigma`,
    /// and each `(region, source)` in `splices` re-rendered from its source.
    static func noiseLevelImage(width: Int, height: Int, sigma: Double, seed: UInt64 = 7, channels: Int = 1,
                                splices: [(Region, NoiseRegionSource)] = []) throws -> PixelBuffer {
        let scene = syntheticScene(width: width, height: height, sceneSeed: 3)
        var generator = SeededGenerator(seed: seed)
        var values = scene.map { $0 + sigma * nextGaussian(&generator) }

        for (region, source) in splices {
            switch source {
            case .noise(let regionSigma, let regionSeed):
                var regionGenerator = SeededGenerator(seed: regionSeed)
                for y in region.y..<(region.y + region.height) {
                    for x in region.x..<(region.x + region.width) {
                        values[y * width + x] = scene[y * width + x] + regionSigma * nextGaussian(&regionGenerator)
                    }
                }
            case .blurred(let radius):
                let original = values
                for y in region.y..<(region.y + region.height) {
                    for x in region.x..<(region.x + region.width) {
                        var sum = 0.0
                        var count = 0.0
                        for dy in -radius...radius {
                            for dx in -radius...radius {
                                let sx = min(width - 1, max(0, x + dx))
                                let sy = min(height - 1, max(0, y + dy))
                                sum += original[sy * width + sx]
                                count += 1
                            }
                        }
                        values[y * width + x] = sum / count
                    }
                }
            }
        }
        return try eightBitBuffer(values, width: width, height: height, channels: channels)
    }

    /// An image of horizontal bands, each a flat `levels[i]` brightness
    /// (with a gentle gradient so it isn't perfectly flat) and noise whose
    /// standard deviation is `noise(level)`: constant for read noise,
    /// growing with brightness for shot noise. No region is edited; any
    /// block flagged is a false positive.
    static func exposureBandsImage(width: Int, height: Int, levels: [Double], noise: (Double) -> Double, seed: UInt64 = 11) throws -> PixelBuffer {
        var generator = SeededGenerator(seed: seed)
        let bandHeight = height / max(1, levels.count)
        var values = [Double](repeating: 0, count: width * height)
        for y in 0..<height {
            let level = levels[min(levels.count - 1, y / max(1, bandHeight))]
            for x in 0..<width {
                let base = level + 6 * sin(Double(x) / 37.0) + 4 * cos(Double(y) / 29.0)
                values[y * width + x] = base + noise(base) * nextGaussian(&generator)
            }
        }
        return try eightBitBuffer(values, width: width, height: height, channels: 1)
    }

    /// Rounds `values` to 8 bits, repeated across `channels` channels.
    static func eightBitBuffer(_ values: [Double], width: Int, height: Int, channels: Int) throws -> PixelBuffer {
        var pixels = [UInt8]()
        pixels.reserveCapacity(values.count * channels)
        for value in values {
            let byte = UInt8(clamping: Int(value.rounded()))
            for _ in 0..<channels { pixels.append(byte) }
        }
        return try PixelBuffer(width: width, height: height, channels: channels, pixels: pixels)
    }
}
