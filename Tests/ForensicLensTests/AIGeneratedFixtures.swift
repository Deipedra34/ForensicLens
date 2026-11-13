import Foundation
import ImageDecoding

/// Synthetic images for the AI-generated image detection tests.
///
/// Real generated images can't be checked into a dependency-free test
/// suite, and wouldn't give known answers anyway, so each fixture isolates
/// one of the two traces the detector looks for:
///
/// - a **camera-like capture**: a smooth scene seen through a simulated
///   sensor (PRNU gain pattern plus read noise, from `PRNUFixtures`), so it
///   carries sensor noise everywhere and no periodic pattern;
/// - an **upsampling pattern**: a fixed periodic grid, a period-2
///   checkerboard plus a weaker period-4 component, which is what a
///   transposed-convolution or pixel-shuffle upsampling stage imprints;
/// - a **noise-free render**: the bare scene, rounded to 8 bits, with no
///   sensor noise at all.
///
/// The "likely fake" fixture is a noise-free render with the upsampling
/// pattern on top; the "likely real" one is a camera-like capture.
/// Everything is seeded, so every run sees the same pixels.
extension Fixtures {
    /// The periodic upsampling artifact at `(x, y)`: a checkerboard of
    /// amplitude `checkerboard` plus a period-4 product of cosines of
    /// amplitude `period4`. Zero-mean over every 4x4 cell.
    static func upsamplingPattern(x: Int, y: Int, checkerboard: Double, period4: Double) -> Double {
        let sign: Double = (x + y) % 2 == 0 ? 1 : -1
        let quarter = cos(Double.pi * Double(x) / 2) * cos(Double.pi * Double(y) / 2)
        return checkerboard * sign + period4 * quarter
    }

    /// A grayscale camera-like capture of `syntheticScene(sceneSeed:)`.
    static func cameraLikeCapture(width: Int = 256, height: Int = 256, sceneSeed: Int = 3, seed: UInt64 = 41) throws -> PixelBuffer {
        let sensor = sensorPattern(width: width, height: height, seed: seed)
        return try simulatedCapture(width: width, height: height, sensor: sensor, sceneSeed: sceneSeed, noiseSeed: seed &+ 1)
    }

    /// `syntheticScene(sceneSeed:)` with no sensor noise at all, plus the
    /// upsampling pattern at the given amplitudes (0 for a plain render).
    static func noiseFreeRender(width: Int = 256, height: Int = 256, sceneSeed: Int = 3, checkerboard: Double = 0, period4: Double = 0) throws -> PixelBuffer {
        let scene = syntheticScene(width: width, height: height, sceneSeed: sceneSeed)
        var pixels = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let value = scene[y * width + x] + upsamplingPattern(x: x, y: y, checkerboard: checkerboard, period4: period4)
                pixels[y * width + x] = UInt8(clamping: Int(value.rounded()))
            }
        }
        return try PixelBuffer(width: width, height: height, channels: 1, pixels: pixels)
    }

    /// `buffer` with the upsampling pattern added on top.
    static func addingUpsamplingPattern(to buffer: PixelBuffer, checkerboard: Double, period4: Double) throws -> PixelBuffer {
        var pixels = buffer.pixels
        let channels = buffer.channels
        for y in 0..<buffer.height {
            for x in 0..<buffer.width {
                let delta = upsamplingPattern(x: x, y: y, checkerboard: checkerboard, period4: period4)
                for c in 0..<channels {
                    let index = (y * buffer.width + x) * channels + c
                    pixels[index] = UInt8(clamping: Int((Double(pixels[index]) + delta).rounded()))
                }
            }
        }
        return try PixelBuffer(width: buffer.width, height: buffer.height, channels: channels, pixels: pixels)
    }

    /// The "likely fake" image: a noise-free render carrying a clear
    /// upsampling pattern.
    static func likelyGeneratedImage(width: Int = 256, height: Int = 256) throws -> PixelBuffer {
        try noiseFreeRender(width: width, height: height, checkerboard: 2.5, period4: 1.5)
    }

    /// The "likely real" image: a camera-like capture with no pattern.
    static func likelyCameraImage(width: Int = 256, height: Int = 256) throws -> PixelBuffer {
        try cameraLikeCapture(width: width, height: height)
    }

    /// A buffer wrapped in an `ImageData` the way a decoded BMP arrives.
    static func imageData(_ buffer: PixelBuffer) throws -> ImageData {
        try ImageData.load(ImageEncoder.encodeBMP(buffer))
    }
}
