import Foundation
import ImageDecoding

/// A 256-bit binary descriptor: one bit per intensity comparison between a
/// pair of sample points around a keypoint. Compared by Hamming distance,
/// which is just four XORs and popcounts.
struct BinaryDescriptor: Sendable, Hashable {
    var w0: UInt64 = 0
    var w1: UInt64 = 0
    var w2: UInt64 = 0
    var w3: UInt64 = 0

    static let bitCount = 256

    mutating func setBit(_ index: Int) {
        let mask = UInt64(1) << UInt64(index & 63)
        switch index >> 6 {
        case 0: w0 |= mask
        case 1: w1 |= mask
        case 2: w2 |= mask
        default: w3 |= mask
        }
    }

    func hammingDistance(to other: BinaryDescriptor) -> Int {
        (w0 ^ other.w0).nonzeroBitCount
            + (w1 ^ other.w1).nonzeroBitCount
            + (w2 ^ other.w2).nonzeroBitCount
            + (w3 ^ other.w3).nonzeroBitCount
    }
}

/// A detected, oriented, described interest point.
struct Keypoint: Sendable, Equatable {
    /// Position in the coordinate space of the buffer it was extracted
    /// from, regardless of which pyramid level found it.
    let position: Point2D

    /// Pyramid level the keypoint was detected on (0 = full resolution).
    let level: Int

    /// How much that level was downscaled relative to level 0.
    let scale: Double

    /// Dominant orientation in radians (intensity-centroid direction).
    let angle: Double

    /// Harris corner response on its own level. Used only to rank and cap
    /// keypoints, never compared across images.
    let response: Float

    let descriptor: BinaryDescriptor

    func offsetBy(dx: Int, dy: Int) -> Keypoint {
        Keypoint(
            position: Point2D(x: position.x + Double(dx), y: position.y + Double(dy)),
            level: level,
            scale: scale,
            angle: angle,
            response: response,
            descriptor: descriptor
        )
    }
}

/// Detects keypoints and computes rotation- and scale-tolerant binary
/// descriptors for them, in the style of ORB (oriented FAST and rotated
/// BRIEF), implemented in plain Swift so it builds identically on macOS and
/// Linux with no external dependency.
///
/// The pipeline, per pyramid level:
///
/// 1. **Scale pyramid.** The luma image is repeatedly downscaled by
///    `scaleFactor` (1.2), up to `maximumLevels` levels. A patch that was
///    enlarged by 1.44x before pasting shows up two levels further down the
///    pyramid at the same apparent size as its source, which is what lets
///    fixed-size descriptors match across a scale change.
/// 2. **Harris corners.** Each level is lightly smoothed (5-tap binomial),
///    and the Harris corner response is computed from its smoothed
///    gradient structure tensor. Local maxima above a threshold relative to
///    the level's strongest response become candidates; the strongest ones,
///    up to the level's share of `maximumKeypoints` (proportional to its
///    area), are kept. ORB uses FAST to find candidates and Harris to rank
///    them; using Harris for both is simpler and its response is itself
///    rotation-invariant, which matters more here than FAST's speed.
/// 3. **Orientation.** The intensity centroid of a radius-15 disc around the
///    keypoint gives a direction that rotates with the image content.
/// 4. **Steered BRIEF.** 256 pairs of sample points from a fixed,
///    seeded Gaussian pattern (radius 13) are rotated by that orientation
///    and compared on the smoothed level, one bit per pair. Because the
///    pattern turns with the content, the same physical corner produces
///    (nearly) the same bits in a rotated copy.
///
/// Keypoints closer to a level's border than the description patch needs
/// are skipped, so every sample stays inside the image.
enum FeatureExtractor {
    static let scaleFactor = 1.2
    static let maximumLevels = 5
    static let orientationRadius = 15
    static let patternRadius = 13.0

    /// Margin, in level pixels, a keypoint must keep from its level's edge.
    static let border = orientationRadius + 2

    private static let harrisK: Float = 0.04
    private static let relativeResponseThreshold: Float = 0.01
    private static let minimumResponse: Float = 1

    /// How far, in full-resolution pixels, a keypoint's support can reach
    /// at the coarsest pyramid level. A tiled scan needs a halo at least
    /// this wide so keypoints near a tile's core edge are still described
    /// from real neighboring pixels rather than skipped.
    static var supportRadius: Int {
        let coarsestScale = pow(scaleFactor, Double(maximumLevels - 1))
        return Int((Double(border + 2) * coarsestScale).rounded(.up))
    }

    /// Extracts up to roughly `maximumKeypoints` keypoints from `buffer`.
    /// Returns an empty array -- never traps -- for an image too small to
    /// hold even one description patch, or one with no corners at all.
    static func extract(from buffer: PixelBuffer, maximumKeypoints: Int) -> [Keypoint] {
        guard maximumKeypoints > 0 else { return [] }
        let levels = pyramid(GrayImage(luma: buffer))
        guard !levels.isEmpty else { return [] }

        let totalArea = levels.reduce(0) { $0 + $1.width * $1.height }
        var keypoints: [Keypoint] = []

        for (level, image) in levels.enumerated() {
            let quota = max(1, Int((Double(maximumKeypoints) * Double(image.width * image.height) / Double(totalArea)).rounded()))
            let smoothed = image.smoothed()
            let corners = strongestCorners(in: smoothed, limit: quota)

            let scaleX = Double(buffer.width) / Double(image.width)
            let scaleY = Double(buffer.height) / Double(image.height)
            for corner in corners {
                let angle = orientation(in: smoothed, x: corner.x, y: corner.y)
                let descriptor = describe(in: smoothed, x: corner.x, y: corner.y, angle: angle)
                // Pixel centers map between levels as (x + 0.5) * scale - 0.5,
                // matching the center-aligned resampling `GrayImage.resized`
                // performs.
                keypoints.append(Keypoint(
                    position: Point2D(x: (Double(corner.x) + 0.5) * scaleX - 0.5, y: (Double(corner.y) + 0.5) * scaleY - 0.5),
                    level: level,
                    scale: (scaleX + scaleY) / 2,
                    angle: angle,
                    response: corner.response,
                    descriptor: descriptor
                ))
            }
        }
        return keypoints
    }

    // MARK: - Pyramid

    private static func pyramid(_ base: GrayImage) -> [GrayImage] {
        let minimumSide = 2 * border + 1
        guard base.width >= minimumSide, base.height >= minimumSide else { return [] }

        var levels = [base]
        var current = base
        for level in 1..<maximumLevels {
            let divisor = pow(scaleFactor, Double(level))
            let width = Int((Double(base.width) / divisor).rounded())
            let height = Int((Double(base.height) / divisor).rounded())
            guard width >= minimumSide, height >= minimumSide else { break }
            current = current.resized(width: width, height: height)
            levels.append(current)
        }
        return levels
    }

    // MARK: - Harris corners

    private struct Corner {
        let x: Int
        let y: Int
        let response: Float
    }

    private static func strongestCorners(in image: GrayImage, limit: Int) -> [Corner] {
        let width = image.width
        let height = image.height
        guard width > 2 * border, height > 2 * border else { return [] }

        // Structure tensor entries from central-difference gradients.
        let count = width * height
        var gxx = [Float](repeating: 0, count: count)
        var gyy = [Float](repeating: 0, count: count)
        var gxy = [Float](repeating: 0, count: count)
        let values = image.values
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let i = y * width + x
                let gx = (values[i + 1] - values[i - 1]) * 0.5
                let gy = (values[i + width] - values[i - width]) * 0.5
                gxx[i] = gx * gx
                gyy[i] = gy * gy
                gxy[i] = gx * gy
            }
        }
        let sxx = GrayImage.binomialSmoothed(gxx, width: width, height: height)
        let syy = GrayImage.binomialSmoothed(gyy, width: width, height: height)
        let sxy = GrayImage.binomialSmoothed(gxy, width: width, height: height)

        var response = [Float](repeating: 0, count: count)
        var strongest: Float = 0
        for i in 0..<count {
            let trace = sxx[i] + syy[i]
            let value = sxx[i] * syy[i] - sxy[i] * sxy[i] - harrisK * trace * trace
            response[i] = value
            strongest = max(strongest, value)
        }

        let threshold = max(minimumResponse, relativeResponseThreshold * strongest)
        var corners: [Corner] = []
        for y in border..<(height - border) {
            for x in border..<(width - border) {
                let i = y * width + x
                let value = response[i]
                guard value > threshold, isLocalMaximum(response, index: i, width: width) else { continue }
                corners.append(Corner(x: x, y: y, response: value))
            }
        }

        corners.sort { lhs, rhs in
            if lhs.response != rhs.response { return lhs.response > rhs.response }
            return (lhs.y, lhs.x) < (rhs.y, rhs.x)
        }
        return Array(corners.prefix(limit))
    }

    /// Strict 3x3 non-maximum suppression. Ties go to whichever pixel comes
    /// first in raster order, so a plateau yields exactly one corner.
    private static func isLocalMaximum(_ response: [Float], index: Int, width: Int) -> Bool {
        let value = response[index]
        for dy in -1...1 {
            for dx in -1...1 where dx != 0 || dy != 0 {
                let neighbor = response[index + dy * width + dx]
                let comesBefore = dy < 0 || (dy == 0 && dx < 0)
                if comesBefore ? neighbor >= value : neighbor > value {
                    return false
                }
            }
        }
        return true
    }

    // MARK: - Orientation

    /// Half-widths of each row of the orientation disc.
    private static let discSpans: [Int] = (-orientationRadius...orientationRadius).map { dy in
        Int(Double(orientationRadius * orientationRadius - dy * dy).squareRoot())
    }

    private static func orientation(in image: GrayImage, x: Int, y: Int) -> Double {
        var m10 = 0.0
        var m01 = 0.0
        for dy in -orientationRadius...orientationRadius {
            let span = discSpans[dy + orientationRadius]
            let row = (y + dy) * image.width
            for dx in -span...span {
                let value = Double(image.values[row + x + dx])
                m10 += Double(dx) * value
                m01 += Double(dy) * value
            }
        }
        return atan2(m01, m10)
    }

    // MARK: - Steered BRIEF

    private struct SamplePair {
        let x1: Double
        let y1: Double
        let x2: Double
        let y2: Double
    }

    /// The fixed BRIEF sampling pattern: `BinaryDescriptor.bitCount` point
    /// pairs drawn from an isotropic Gaussian (sigma = patch size / 5, as in
    /// the original BRIEF paper) and rejected outside `patternRadius`, so
    /// rotating a pair by any angle keeps it inside the same disc. Seeded,
    /// so every run -- and every platform -- uses the same pattern.
    private static let pattern: [SamplePair] = {
        var generator = SplitMix64(seed: 0x0B5E_ED0F_B41E_F000)
        let sigma = (2 * patternRadius + 1) / 5
        func gaussianPoint() -> (Double, Double) {
            // Rejection sampling; ~98% of draws land inside the disc, so the
            // bound is never reached in practice -- it only keeps this
            // provably finite.
            for _ in 0..<1000 {
                let u1 = max(generator.nextUnitInterval(), 1e-12)
                let u2 = generator.nextUnitInterval()
                let radius = (-2 * log(u1)).squareRoot() * sigma
                let x = radius * cos(2 * Double.pi * u2)
                let y = radius * sin(2 * Double.pi * u2)
                if x * x + y * y <= patternRadius * patternRadius {
                    return (x, y)
                }
            }
            return (0, 0)
        }
        return (0..<BinaryDescriptor.bitCount).map { _ in
            let first = gaussianPoint()
            let second = gaussianPoint()
            return SamplePair(x1: first.0, y1: first.1, x2: second.0, y2: second.1)
        }
    }()

    private static func describe(in image: GrayImage, x: Int, y: Int, angle: Double) -> BinaryDescriptor {
        let cosine = cos(angle)
        let sine = sin(angle)
        let cx = Double(x)
        let cy = Double(y)
        var descriptor = BinaryDescriptor()
        for (bit, pair) in pattern.enumerated() {
            let first = image.bilinearSample(x: cx + cosine * pair.x1 - sine * pair.y1, y: cy + sine * pair.x1 + cosine * pair.y1)
            let second = image.bilinearSample(x: cx + cosine * pair.x2 - sine * pair.y2, y: cy + sine * pair.x2 + cosine * pair.y2)
            if first < second {
                descriptor.setBit(bit)
            }
        }
        return descriptor
    }
}

/// A single-channel floating-point image plane used by feature extraction.
struct GrayImage: Sendable {
    let width: Int
    let height: Int
    let values: [Float]

    init(width: Int, height: Int, values: [Float]) {
        self.width = width
        self.height = height
        self.values = values
    }

    init(luma buffer: PixelBuffer) {
        var values = [Float](repeating: 0, count: buffer.width * buffer.height)
        for y in 0..<buffer.height {
            for x in 0..<buffer.width {
                values[y * buffer.width + x] = Float(buffer.luma(x: x, y: y))
            }
        }
        self.init(width: buffer.width, height: buffer.height, values: values)
    }

    /// Bilinear, pixel-center-aligned resampling to `width` x `height`.
    func resized(width newWidth: Int, height newHeight: Int) -> GrayImage {
        let ratioX = Double(width) / Double(newWidth)
        let ratioY = Double(height) / Double(newHeight)
        var output = [Float](repeating: 0, count: newWidth * newHeight)
        for y in 0..<newHeight {
            let fy = (Double(y) + 0.5) * ratioY - 0.5
            let iy = Int(fy.rounded(.down))
            let ay = Float(fy - Double(iy))
            let y0 = min(height - 1, max(0, iy))
            let y1 = min(height - 1, max(0, iy + 1))
            for x in 0..<newWidth {
                let fx = (Double(x) + 0.5) * ratioX - 0.5
                let ix = Int(fx.rounded(.down))
                let ax = Float(fx - Double(ix))
                let x0 = min(width - 1, max(0, ix))
                let x1 = min(width - 1, max(0, ix + 1))
                let top = values[y0 * width + x0] * (1 - ax) + values[y0 * width + x1] * ax
                let bottom = values[y1 * width + x0] * (1 - ax) + values[y1 * width + x1] * ax
                output[y * newWidth + x] = top * (1 - ay) + bottom * ay
            }
        }
        return GrayImage(width: newWidth, height: newHeight, values: output)
    }

    func smoothed() -> GrayImage {
        GrayImage(width: width, height: height, values: Self.binomialSmoothed(values, width: width, height: height))
    }

    /// Bilinear sample at a sub-pixel position. The caller keeps `(x, y)`
    /// at least one pixel inside the image (feature extraction's border
    /// margin guarantees this); positions outside are clamped rather than
    /// trapping, just in case.
    func bilinearSample(x: Double, y: Double) -> Float {
        let ix = min(width - 2, max(0, Int(x.rounded(.down))))
        let iy = min(height - 2, max(0, Int(y.rounded(.down))))
        let ax = Float(min(1, max(0, x - Double(ix))))
        let ay = Float(min(1, max(0, y - Double(iy))))
        let i = iy * width + ix
        let top = values[i] * (1 - ax) + values[i + 1] * ax
        let bottom = values[i + width] * (1 - ax) + values[i + width + 1] * ax
        return top * (1 - ay) + bottom * ay
    }

    /// Separable 5-tap binomial blur ([1, 4, 6, 4, 1] / 16, a close
    /// approximation of a Gaussian with sigma = 1), clamping at the edges.
    static func binomialSmoothed(_ values: [Float], width: Int, height: Int) -> [Float] {
        let weights: [Float] = [1.0 / 16, 4.0 / 16, 6.0 / 16, 4.0 / 16, 1.0 / 16]
        var horizontal = [Float](repeating: 0, count: values.count)
        for y in 0..<height {
            let row = y * width
            for x in 0..<width {
                var sum: Float = 0
                for k in 0..<5 {
                    let xx = min(width - 1, max(0, x + k - 2))
                    sum += weights[k] * values[row + xx]
                }
                horizontal[row + x] = sum
            }
        }
        var output = [Float](repeating: 0, count: values.count)
        for y in 0..<height {
            for x in 0..<width {
                var sum: Float = 0
                for k in 0..<5 {
                    let yy = min(height - 1, max(0, y + k - 2))
                    sum += weights[k] * horizontal[yy * width + x]
                }
                output[y * width + x] = sum
            }
        }
        return output
    }
}
