import Foundation
import ImageDecoding

/// Synthetic "camera" captures for the PRNU tests.
///
/// A simulated sensor is a fixed per-pixel gain pattern `K` (its PRNU).
/// A capture of a scene `I` through that sensor records
/// `I * (1 + K) + read noise`, rounded to 8 bits, which is the
/// multiplicative-plus-additive noise model the PRNU literature uses for a
/// real sensor. Every value comes from a fixed seed, so each test sees the
/// same images on every run.
extension Fixtures {
    /// A standard normal deviate (Box-Muller), drawn from the high bits of
    /// two `SeededGenerator` outputs.
    static func nextGaussian(_ generator: inout SeededGenerator) -> Double {
        let u1 = (Double(generator.next() >> 11) + 1) / 9_007_199_254_740_993.0
        let u2 = Double(generator.next() >> 11) / 9_007_199_254_740_992.0
        return (-2 * log(u1)).squareRoot() * cos(2 * Double.pi * u2)
    }

    /// A simulated sensor's PRNU gain pattern: independent Gaussian
    /// per-pixel deviations with standard deviation `strength` (2% here,
    /// within the range reported for real sensors).
    static func sensorPattern(width: Int, height: Int, seed: UInt64, strength: Double = 0.02) -> [Double] {
        var generator = SeededGenerator(seed: seed)
        return (0..<(width * height)).map { _ in strength * nextGaussian(&generator) }
    }

    /// A smooth, noise-free scene, mid-gray with gentle gradients and no
    /// clipping. `sceneSeed` shifts its phases and frequencies, so
    /// different seeds give different content.
    static func syntheticScene(width: Int, height: Int, sceneSeed: Int) -> [Double] {
        let phase1 = Double(sceneSeed) * 1.7
        let phase2 = Double(sceneSeed) * 0.9
        let frequency1 = 23.0 + 3.0 * Double(sceneSeed % 5)
        let frequency2 = 17.0 + 2.0 * Double(sceneSeed % 3)
        var values = [Double](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                values[y * width + x] = 110 + 50 * sin(Double(x) / frequency1 + phase1) + 30 * cos(Double(y) / frequency2 + Double(x) / 41.0 + phase2)
            }
        }
        return values
    }

    /// One grayscale capture of scene `sceneSeed` through the sensor whose
    /// PRNU pattern is `sensor`, with Gaussian read noise of standard
    /// deviation `readNoise` drawn from `noiseSeed`.
    static func simulatedCapture(width: Int, height: Int, sensor: [Double], sceneSeed: Int, noiseSeed: UInt64, readNoise: Double = 2) throws -> PixelBuffer {
        let scene = syntheticScene(width: width, height: height, sceneSeed: sceneSeed)
        var generator = SeededGenerator(seed: noiseSeed)
        let pixels = (0..<(width * height)).map { i in
            eightBit(scene[i] * (1 + sensor[i]) + readNoise * nextGaussian(&generator))
        }
        return try PixelBuffer(width: width, height: height, channels: 1, pixels: pixels)
    }

    /// How a spliced-in region's pixels were produced.
    enum SpliceSource {
        /// The bare scene, with no sensor noise at all: a synthetic or
        /// fully denoised paste.
        case noiseFree
        /// The scene plus noise that was spatially smoothed (a
        /// `2 * radius + 1` box filter of white noise, rescaled to standard
        /// deviation `amplitude`), as noise from a region that was
        /// resampled, filtered, or captured by a different pipeline looks.
        case smoothedNoise(radius: Int, amplitude: Double, seed: UInt64)
    }

    /// `buffer` (a grayscale capture of `sceneSeed`) with the
    /// `size` x `size` region at `(x, y)` re-rendered from `source`.
    static func splicing(_ source: SpliceSource, sceneSeed: Int, at x: Int, _ y: Int, size: Int, into buffer: PixelBuffer) throws -> PixelBuffer {
        let width = buffer.width
        let height = buffer.height
        let scene = syntheticScene(width: width, height: height, sceneSeed: sceneSeed)
        var pixels = buffer.pixels

        var noise = [Double](repeating: 0, count: width * height)
        var radius = 0
        var amplitude = 0.0
        if case .smoothedNoise(let r, let a, let seed) = source {
            radius = r
            amplitude = a
            var generator = SeededGenerator(seed: seed)
            noise = (0..<(width * height)).map { _ in nextGaussian(&generator) }
        }

        for row in y..<(y + size) {
            for col in x..<(x + size) {
                var value = scene[row * width + col]
                if radius > 0 {
                    var sum = 0.0
                    for dy in -radius...radius {
                        for dx in -radius...radius {
                            sum += noise[min(height - 1, max(0, row + dy)) * width + min(width - 1, max(0, col + dx))]
                        }
                    }
                    // A sum of n unit-variance samples has standard
                    // deviation sqrt(n) = 2 * radius + 1.
                    value += amplitude * sum / Double(2 * radius + 1)
                }
                pixels[row * width + col] = eightBit(value)
            }
        }
        return try PixelBuffer(width: width, height: height, channels: 1, pixels: pixels)
    }

    private static func eightBit(_ value: Double) -> UInt8 {
        UInt8(clamping: Int(value.rounded()))
    }
}
