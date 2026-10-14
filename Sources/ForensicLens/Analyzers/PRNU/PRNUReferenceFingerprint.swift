import Foundation
import ImageDecoding

/// Errors raised while building a reference PRNU fingerprint.
public enum PRNUReferenceError: Error, Equatable, CustomStringConvertible {
    /// The reference folder doesn't exist or isn't a directory.
    case folderNotFound(String)

    /// The reference folder exists but couldn't be listed.
    case unreadableFolder(path: String, reason: String)

    /// Fewer reference images than `PRNUReferenceFingerprint.minimumImageCount`.
    case tooFewImages(found: Int, required: Int)

    /// A reference image's size differs from the first one's. A
    /// fingerprint is a per-pixel pattern, so every image averaged into it
    /// has to come from the same sensor area at the same resolution and
    /// orientation.
    case mismatchedDimensions(image: String, width: Int, height: Int, expectedWidth: Int, expectedHeight: Int)

    /// A reference file is a recognized image format, but its pixels
    /// couldn't be decoded.
    case undecodableImage(image: String, reason: String)

    /// The averaged fingerprint is (numerically) zero: the reference images
    /// have no measurable noise residual, e.g. because they're uniform or
    /// synthetic.
    case noMeasurableNoise

    public var description: String {
        switch self {
        case .folderNotFound(let path):
            return "PRNU reference folder \"\(path)\" does not exist or is not a directory."
        case .unreadableFolder(let path, let reason):
            return "Could not list PRNU reference folder \"\(path)\": \(reason)"
        case .tooFewImages(let found, let required):
            return "PRNU reference fingerprint needs at least \(required) images from the same camera, found \(found). "
                + "Use \(PRNUReferenceFingerprint.recommendedImageCount) or more for a reliable fingerprint."
        case .mismatchedDimensions(let image, let width, let height, let expectedWidth, let expectedHeight):
            return "PRNU reference image \"\(image)\" is \(width)x\(height), but the first reference image is \(expectedWidth)x\(expectedHeight). "
                + "Every reference image must be a full-resolution, unrotated, uncropped capture from the same camera."
        case .undecodableImage(let image, let reason):
            return "Could not decode PRNU reference image \"\(image)\": \(reason)"
        case .noMeasurableNoise:
            return "The PRNU reference images have no measurable sensor noise (uniform or synthetic images?), so no fingerprint could be built."
        }
    }
}

/// The result of checking one image against a `PRNUReferenceFingerprint`.
public struct PRNUReferenceVerification: Sendable, Equatable {
    public enum Outcome: String, Sendable, Equatable {
        /// PCE at or above `PRNUReferenceFingerprint.matchThreshold`: the
        /// image's sensor noise carries the reference camera's pattern.
        case match
        /// PCE below the threshold: the reference camera's pattern isn't
        /// detectably present.
        case mismatch
        /// The image's size differs from the reference images', so the
        /// patterns can't be lined up pixel for pixel. Nothing is concluded.
        case dimensionMismatch
        /// The image has no measurable noise residual to correlate.
        case noMeasurableNoise
    }

    public let outcome: Outcome

    /// Normalized correlation at zero shift between the image's residual
    /// and the fingerprint (modulated by the image's own brightness).
    public let peakCorrelation: Double?

    /// Peak-to-correlation energy; see `PRNUCorrelation.peakToCorrelationEnergy`.
    public let peakToCorrelationEnergy: Double?

    public let referenceImageCount: Int

    /// `true` when the fingerprint was averaged from fewer than
    /// `PRNUReferenceFingerprint.recommendedImageCount` images. A thin
    /// fingerprint still carries scene content and random noise from its
    /// few sources, which weakens both a match and, especially, a mismatch.
    public var isLowConfidence: Bool {
        referenceImageCount < PRNUReferenceFingerprint.recommendedImageCount
    }
}

/// A camera's reference PRNU fingerprint, estimated from several images
/// known to come from that camera, plus the test that correlates another
/// image against it.
///
/// The estimate is the standard maximum-likelihood one (Chen, Fridrich,
/// Goljan & Lukas, 2008): with `W_i` each reference image's noise residual
/// and `I_i` its luminance, `K = sum(W_i * I_i) / sum(I_i^2)` per pixel,
/// then zero-meaned to remove row and column artifacts that sensors of the
/// same model share. Because PRNU is multiplicative (a pixel's deviation is
/// proportional to the light it received), an image from this camera should
/// have a residual that correlates with `I * K`. That correlation is
/// measured by PCE (`PRNUCorrelation.peakToCorrelationEnergy`).
///
/// This only means something under specific conditions:
///
/// - **Several images from one camera.** Each image's residual is mostly
///   random noise plus some scene leakage, and averaging is what cancels
///   both. At least `minimumImageCount` are required. Fewer than
///   `recommendedImageCount` are accepted but flagged as low confidence.
///   Smooth, bright, in-focus scenes (sky, walls) give the cleanest
///   estimates.
/// - **Native, unedited captures.** Resizing, cropping, rotating or
///   heavily recompressing an image moves or destroys the per-pixel
///   pattern. Reference images must all share one resolution and
///   orientation, and the image under test must match it.
///
/// Only a central region of at most `maximumWorkingDimension` x
/// `maximumWorkingDimension` pixels, at native resolution, is used for both
/// the fingerprint and the test. Downsampling would average the per-pixel
/// pattern away, and a central crop still holds plenty of pixels for PCE to
/// discriminate, while bounding memory (the FFT stage holds several
/// `Double` planes of that size) and time.
public struct PRNUReferenceFingerprint: Sendable, Equatable {
    /// Fewest reference images accepted at all.
    public static let minimumImageCount = 2

    /// Fewest reference images for a result that isn't flagged as low
    /// confidence.
    public static let recommendedImageCount = 10

    /// PCE at or above which an image counts as matching the fingerprint.
    /// 60 is the decision threshold commonly used in the PRNU literature
    /// (Goljan et al., 2009), set for a very low false-match rate.
    public static let matchThreshold = 60.0

    /// Width and height of the reference images (and so of any image that
    /// can be verified against this fingerprint).
    public let imageWidth: Int
    public let imageHeight: Int

    /// How many reference images were averaged.
    public let imageCount: Int

    /// The central region the fingerprint covers, in image coordinates.
    public let analysisRegion: Region

    /// The fingerprint itself, `analysisRegion`-sized.
    let pattern: PRNUPlane

    /// Builds a fingerprint from already-decoded reference images.
    /// `labels` name the images in error messages; any image without a
    /// label is called "reference image #n".
    ///
    /// - Throws: `PRNUReferenceError` if there are too few images, their
    ///   sizes differ, or they carry no measurable noise.
    public static func build(from images: [PixelBuffer], labels: [String] = [], maximumWorkingDimension: Int) throws -> PRNUReferenceFingerprint {
        var accumulator = Accumulator(maximumWorkingDimension: maximumWorkingDimension)
        for (index, image) in images.enumerated() {
            try accumulator.add(image, label: index < labels.count ? labels[index] : "reference image #\(index + 1)")
        }
        return try accumulator.finish()
    }

    /// Builds a fingerprint from every decodable image directly inside
    /// `path`, not its subfolders, in file-name order. Files that aren't a
    /// recognized image format are skipped. A recognized image that can't
    /// be decoded is an error, not a skip: silently building the
    /// fingerprint from fewer images than the folder holds would make the
    /// result look more trustworthy than it is. Images are decoded and
    /// folded in one at a time, so memory stays bounded by one decoded
    /// image plus the fingerprint, however many references there are.
    public static func load(fromFolder path: String, maximumWorkingDimension: Int) throws -> PRNUReferenceFingerprint {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw PRNUReferenceError.folderNotFound(path)
        }

        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: path).filter { !$0.hasPrefix(".") }.sorted()
        } catch {
            throw PRNUReferenceError.unreadableFolder(path: path, reason: "\(error)")
        }

        var accumulator = Accumulator(maximumWorkingDimension: maximumWorkingDimension)
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        for name in names {
            let filePath = folder.appendingPathComponent(name).path
            var isSubdirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: filePath, isDirectory: &isSubdirectory), !isSubdirectory.boolValue else { continue }
            guard let data = FileManager.default.contents(atPath: filePath) else {
                throw PRNUReferenceError.undecodableImage(image: name, reason: "the file could not be read.")
            }
            let bytes = [UInt8](data)
            guard ImageFormat.detect(from: bytes) != nil else { continue }

            let image: ImageData
            do {
                image = try ImageData.load(bytes)
            } catch {
                throw PRNUReferenceError.undecodableImage(image: name, reason: "\(error)")
            }
            guard let pixels = image.pixels else {
                throw PRNUReferenceError.undecodableImage(
                    image: name,
                    reason: "its pixel data can't be decoded by this build (JPEG pixel decoding isn't supported yet). Convert reference images to BMP or PPM first."
                )
            }
            try accumulator.add(pixels, label: name)
        }
        return try accumulator.finish()
    }

    /// Loads the fingerprint `settings.referenceFolder` names, or returns
    /// `nil` when PRNU analysis is disabled or no folder is configured.
    public static func loadIfConfigured(_ settings: ForensicLensConfig.PRNUConfig) throws -> PRNUReferenceFingerprint? {
        guard settings.enabled, let folder = settings.referenceFolder else { return nil }
        return try load(fromFolder: folder, maximumWorkingDimension: settings.maximumWorkingDimension)
    }

    /// The central region of a `width` x `height` image, at most
    /// `maximumWorkingDimension` on a side, that fingerprinting and
    /// verification use.
    static func analysisRegion(width: Int, height: Int, maximumWorkingDimension: Int) -> Region {
        let cap = max(PRNUAnalyzer.minimumWorkingDimension, maximumWorkingDimension)
        let regionWidth = min(width, cap)
        let regionHeight = min(height, cap)
        return Region(x: (width - regionWidth) / 2, y: (height - regionHeight) / 2, width: regionWidth, height: regionHeight)
    }

    /// Correlates `image` against this fingerprint.
    public func verify(_ image: PixelBuffer) -> PRNUReferenceVerification {
        guard image.width == imageWidth, image.height == imageHeight else {
            return PRNUReferenceVerification(outcome: .dimensionMismatch, peakCorrelation: nil, peakToCorrelationEnergy: nil, referenceImageCount: imageCount)
        }

        let luma = PRNUPlane.luminance(of: image).cropped(to: analysisRegion)
        let residual = PRNUResidualExtractor.residual(of: luma)
        var expected = pattern
        for i in 0..<min(expected.values.count, luma.values.count) {
            expected.values[i] *= luma.values[i]
        }

        guard let result = PRNUCorrelation.peakToCorrelationEnergy(residual, expected) else {
            return PRNUReferenceVerification(outcome: .noMeasurableNoise, peakCorrelation: nil, peakToCorrelationEnergy: nil, referenceImageCount: imageCount)
        }
        return PRNUReferenceVerification(
            outcome: result.peakToCorrelationEnergy >= Self.matchThreshold ? .match : .mismatch,
            peakCorrelation: result.peakCorrelation,
            peakToCorrelationEnergy: result.peakToCorrelationEnergy,
            referenceImageCount: imageCount
        )
    }

    /// Folds reference images into the maximum-likelihood estimate one at
    /// a time.
    private struct Accumulator {
        let maximumWorkingDimension: Int
        var imageWidth = 0
        var imageHeight = 0
        var region: Region?
        var numerator: [Double] = []
        var denominator: [Double] = []
        var count = 0

        init(maximumWorkingDimension: Int) {
            self.maximumWorkingDimension = maximumWorkingDimension
        }

        mutating func add(_ image: PixelBuffer, label: String) throws {
            let analysisRegion: Region
            if let region {
                guard image.width == imageWidth, image.height == imageHeight else {
                    throw PRNUReferenceError.mismatchedDimensions(image: label, width: image.width, height: image.height, expectedWidth: imageWidth, expectedHeight: imageHeight)
                }
                analysisRegion = region
            } else {
                imageWidth = image.width
                imageHeight = image.height
                analysisRegion = PRNUReferenceFingerprint.analysisRegion(width: image.width, height: image.height, maximumWorkingDimension: maximumWorkingDimension)
                region = analysisRegion
                numerator = [Double](repeating: 0, count: analysisRegion.width * analysisRegion.height)
                denominator = numerator
            }

            let luma = PRNUPlane.luminance(of: image).cropped(to: analysisRegion)
            let residual = PRNUResidualExtractor.residual(of: luma)
            for i in 0..<min(numerator.count, luma.values.count) {
                let intensity = luma.values[i]
                // Clipped pixels recorded no sensor response to scale, so
                // they carry no PRNU and are left out of the estimate.
                guard intensity > 2, intensity < 253 else { continue }
                numerator[i] += residual.values[i] * intensity
                denominator[i] += intensity * intensity
            }
            count += 1
        }

        func finish() throws -> PRNUReferenceFingerprint {
            guard count >= PRNUReferenceFingerprint.minimumImageCount, let region else {
                throw PRNUReferenceError.tooFewImages(found: count, required: PRNUReferenceFingerprint.minimumImageCount)
            }

            var estimate = [Double](repeating: 0, count: numerator.count)
            var energy = 0.0
            for i in 0..<estimate.count where denominator[i] > 0 {
                estimate[i] = numerator[i] / denominator[i]
            }
            let pattern = PRNUResidualExtractor.zeroMeaned(PRNUPlane(width: region.width, height: region.height, values: estimate))
            for value in pattern.values { energy += value * value }
            guard energy > PRNUCorrelation.tinyEnergy * Double(max(1, pattern.values.count)) else {
                throw PRNUReferenceError.noMeasurableNoise
            }

            return PRNUReferenceFingerprint(
                imageWidth: imageWidth,
                imageHeight: imageHeight,
                imageCount: count,
                analysisRegion: region,
                pattern: pattern
            )
        }
    }
}
