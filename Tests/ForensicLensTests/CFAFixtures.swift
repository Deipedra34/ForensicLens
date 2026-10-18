import Foundation
import ImageDecoding

/// Synthetic Bayer-sensor captures for the CFA tests.
///
/// A smooth RGB scene is sampled through an RGGB Bayer mosaic (red at even
/// x and y, blue at odd x and y, green on the other checkerboard half) with
/// Gaussian sensor noise at each recorded sample. It's then bilinearly
/// demosaiced: each missing color is the mean of the nearest recorded
/// samples of that color, horizontally/vertically if there are any, else
/// diagonally, mirroring at the image edges. That's the textbook camera
/// pipeline, so the output carries the period-2 interpolation pattern
/// `CFAAnalyzer` looks for. Everything is seeded and deterministic.
extension Fixtures {
    /// A smooth, unclipped RGB scene with some fine detail, as three planes.
    static func cfaScene(width: Int, height: Int, sceneSeed: Int) -> [[Double]] {
        let phase = Double(sceneSeed) * 1.3
        var red = [Double](repeating: 0, count: width * height)
        var green = red
        var blue = red
        for y in 0..<height {
            for x in 0..<width {
                let base = 110 + 45 * sin(Double(x) / 9.0 + phase) * cos(Double(y) / 13.0) + 25 * sin(Double(x + 2 * y) / 5.5 + phase)
                let i = y * width + x
                red[i] = base * 1.05 + 10 * sin(Double(y) / 7.0)
                green[i] = base
                blue[i] = base * 0.9 + 12 * cos(Double(x) / 6.0)
            }
        }
        return [red, green, blue]
    }

    /// The channel (0 red, 1 green, 2 blue) an RGGB sensor records at
    /// `(x, y)`, with its grid shifted by `(offsetX, offsetY)`.
    static func bayerChannel(x: Int, y: Int, offsetX: Int = 0, offsetY: Int = 0) -> Int {
        let px = (x + offsetX) & 1
        let py = (y + offsetY) & 1
        if px == 0 && py == 0 { return 0 }
        if px == 1 && py == 1 { return 2 }
        return 1
    }

    /// A demosaiced RGB capture of `cfaScene(sceneSeed:)` (see this
    /// extension's doc comment). `offsetX`/`offsetY` shift the Bayer grid,
    /// as a photo from a sensor read out (or later cropped) at a different
    /// offset would.
    static func demosaicedCapture(width: Int, height: Int, sceneSeed: Int, noiseSeed: UInt64, noise: Double = 2, offsetX: Int = 0, offsetY: Int = 0) throws -> PixelBuffer {
        let scene = cfaScene(width: width, height: height, sceneSeed: sceneSeed)
        var generator = SeededGenerator(seed: noiseSeed)
        var mosaic = [Double](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            let channel = bayerChannel(x: i % width, y: i / width, offsetX: offsetX, offsetY: offsetY)
            mosaic[i] = scene[channel][i] + noise * nextGaussian(&generator)
        }

        func reflect(_ value: Int, _ count: Int) -> Int {
            let mirrored = value < 0 ? -value : value
            return mirrored < count ? mirrored : 2 * count - 2 - mirrored
        }
        func sample(_ x: Int, _ y: Int) -> (value: Double, channel: Int) {
            let rx = reflect(x, width)
            let ry = reflect(y, height)
            return (mosaic[ry * width + rx], bayerChannel(x: rx, y: ry, offsetX: offsetX, offsetY: offsetY))
        }

        var pixels = [UInt8](repeating: 0, count: width * height * 3)
        let orthogonal = [(-1, 0), (1, 0), (0, -1), (0, 1)]
        let diagonal = [(-1, -1), (1, -1), (-1, 1), (1, 1)]
        for y in 0..<height {
            for x in 0..<width {
                let own = sample(x, y)
                for channel in 0..<3 {
                    var value = own.value
                    if own.channel != channel {
                        var neighbors = orthogonal.map { sample(x + $0.0, y + $0.1) }.filter { $0.channel == channel }
                        if neighbors.isEmpty {
                            neighbors = diagonal.map { sample(x + $0.0, y + $0.1) }.filter { $0.channel == channel }
                        }
                        value = neighbors.reduce(0.0) { $0 + $1.value } / Double(max(1, neighbors.count))
                    }
                    pixels[(y * width + x) * 3 + channel] = UInt8(clamping: Int(value.rounded()))
                }
            }
        }
        return try PixelBuffer(width: width, height: height, channels: 3, pixels: pixels)
    }

    /// How a CFA test splice's pixels are produced.
    enum CFASpliceSource {
        /// Independent random bytes per channel.
        case randomPixels(seed: UInt64)
        /// The scene rendered straight to RGB with noise but no mosaic, as
        /// a rendered, generated, or heavily processed patch would be.
        case withoutMosaic(sceneSeed: Int, seed: UInt64)
        /// The same pixels from `capture`, a capture with its own (e.g.
        /// shifted) Bayer grid.
        case otherCapture(PixelBuffer)
        /// The quarter-size region at half the splice position, enlarged
        /// 2x by pixel duplication.
        case nearestUpsampled
    }

    /// `buffer` with its `size` x `size` region at `(x, y)` replaced from `source`.
    static func splicingCFA(_ source: CFASpliceSource, at x: Int, _ y: Int, size: Int, into buffer: PixelBuffer) throws -> PixelBuffer {
        let width = buffer.width
        var pixels = buffer.pixels
        var generator = SeededGenerator(seed: 0)
        var scene: [[Double]] = []
        switch source {
        case .randomPixels(let seed):
            generator = SeededGenerator(seed: seed)
        case .withoutMosaic(let sceneSeed, let seed):
            generator = SeededGenerator(seed: seed)
            scene = cfaScene(width: width, height: buffer.height, sceneSeed: sceneSeed)
        case .otherCapture, .nearestUpsampled:
            break
        }

        for row in y..<(y + size) {
            for col in x..<(x + size) {
                let i = row * width + col
                for channel in 0..<3 {
                    let value: UInt8
                    switch source {
                    case .randomPixels:
                        value = UInt8(truncatingIfNeeded: generator.next() >> 56)
                    case .withoutMosaic:
                        value = UInt8(clamping: Int((scene[channel][i] + 2 * nextGaussian(&generator)).rounded()))
                    case .otherCapture(let capture):
                        value = capture.pixels[i * 3 + channel]
                    case .nearestUpsampled:
                        let sourceIndex = (y / 2 + (row - y) / 2) * width + x / 2 + (col - x) / 2
                        value = buffer.pixels[sourceIndex * 3 + channel]
                    }
                    pixels[i * 3 + channel] = value
                }
            }
        }
        return try PixelBuffer(width: width, height: buffer.height, channels: 3, pixels: pixels)
    }

    /// A `size` x `size` image of the scene rendered to RGB with noise but
    /// no mosaic anywhere.
    static func renderedWithoutMosaic(size: Int, sceneSeed: Int, seed: UInt64) throws -> PixelBuffer {
        let blank = try PixelBuffer(width: size, height: size, channels: 3, pixels: [UInt8](repeating: 0, count: size * size * 3))
        return try splicingCFA(.withoutMosaic(sceneSeed: sceneSeed, seed: seed), at: 0, 0, size: size, into: blank)
    }
}
