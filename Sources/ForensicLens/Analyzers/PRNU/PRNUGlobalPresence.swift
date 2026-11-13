import ImageDecoding

/// The result of asking whether an image carries camera-like sensor noise
/// anywhere across its extent (see `PRNUGlobalPresence`).
struct PRNUPresenceAssessment: Sendable, Equatable {
    enum Status: Sendable, Equatable {
        /// Enough blocks were usable for the counts below to mean something.
        case assessed
        /// Too small, too clipped, or otherwise unusable, for the reason
        /// given. Counts may be partial.
        case insufficientData(String)
    }

    let status: Status

    /// Blocks that weren't mostly clipped to pure black or white.
    let reliableBlockCount: Int

    /// Reliable blocks whose residual looks like sensor noise: strong
    /// enough, and without strong correlation at any short lag.
    let sensorLikeBlockCount: Int

    /// Median residual standard deviation over the reliable blocks, in
    /// working-resolution gray levels.
    let medianNoiseLevel: Double

    /// The fraction of reliable blocks that carry sensor-like noise, 0 to
    /// 1 (0 if there are none).
    var coverage: Double {
        reliableBlockCount > 0 ? Double(sensorLikeBlockCount) / Double(reliableBlockCount) : 0
    }

    var isAssessed: Bool { status == .assessed }
}

/// Checks whether an image shows a coherent camera sensor-noise
/// fingerprint *anywhere* across its full extent: the global
/// "PRNU-absence" check behind AI-generated image detection.
///
/// **How this differs from `PRNULocalConsistency`.** The local check asks
/// "does any block's noise disagree with the rest of this image?". It
/// assumes a real photograph that may have been edited, uses the image's
/// own aggregate noise as the reference, and flags outliers. An image
/// whose noise is uniformly *absent* (or uniformly non-sensor-like) has no
/// outliers, so the local check correctly reports it as consistent. That
/// is exactly the profile of a fully synthetic image: there's no real
/// photo underneath for an edited region to disagree with. This check
/// fills that gap. It applies an absolute, image-independent test to every
/// block, "does this block's residual look like sensor noise at all?", and
/// reports the share of blocks that pass. A camera photo, even a locally
/// tampered one, keeps sensor noise in its untouched regions, so most of
/// its blocks pass. An image produced without a sensor typically has
/// none or very few that do.
///
/// The two checks complement each other and share every building block:
/// the same luminance plane, working-resolution downsampling, wavelet
/// noise residual (`PRNUResidualExtractor`), block noise signatures
/// (`PRNUCorrelation.noiseSignature`), and clipped-block filter. Only the
/// question asked of the signatures differs.
///
/// **What "sensor-like" means here.** Without a reference camera, a single
/// image can't reveal *which* sensor made it (a PRNU pattern is unique per
/// pixel, so nothing else in the frame says what it should be). What it can
/// show is whether the residual has the character sensor noise always has.
/// A block passes when both hold:
///
/// - **Enough of it**: residual standard deviation at least
///   `minimumSensorNoiseLevel`. Shot noise, read noise and PRNU together
///   leave a camera image well above this even at low ISO; a rendered or
///   generated image, or a heavily denoised one, often falls below it.
/// - **Close to white**: no correlation coefficient beyond
///   `maximumLagCorrelation` (in magnitude) at any of the 12 short lags
///   the noise signature measures. Sensor noise, even after demosaicing,
///   is only mildly correlated between neighbors; smooth synthetic texture,
///   upsampled noise and periodic patterns are strongly correlated at
///   some short lag.
enum PRNUGlobalPresence {
    /// Smallest residual standard deviation, in working-resolution gray
    /// levels, that counts as sensor-like noise. About twice the ~0.29
    /// that 8-bit rounding alone leaves, and well under the 1.5 to 3 levels
    /// typical of an unprocessed camera capture's residual.
    static let minimumSensorNoiseLevel = 0.6

    /// Largest magnitude of any short-lag correlation coefficient that
    /// still counts as near-white, sensor-like noise.
    static let maximumLagCorrelation = 0.7

    /// Whether one block's noise signature looks like camera sensor noise
    /// (see this type's doc comment).
    static func isSensorLike(_ signature: PRNUCorrelation.NoiseSignature) -> Bool {
        guard signature.standardDeviation >= minimumSensorNoiseLevel,
              let correlations = signature.lagCorrelations,
              !correlations.isEmpty
        else { return false }
        return correlations.allSatisfy { abs($0) <= maximumLagCorrelation }
    }

    /// Assesses a decoded image, seeing it exactly the way PRNU local
    /// consistency does: the same `blockSize` (raised to
    /// `PRNUAnalyzer.minimumBlockSize`) and the same integer box
    /// downsampling to `maximumWorkingDimension`, so the two PRNU-based
    /// checks agree on which noise they're looking at. Downsampling by a
    /// factor `s` averages independent noise down by about `s`, so the noise
    /// level bar is lowered by the same factor to stay comparable.
    static func assess(_ buffer: PixelBuffer, settings: ForensicLensConfig.PRNUConfig) -> PRNUPresenceAssessment {
        let blockSize = max(PRNUAnalyzer.minimumBlockSize, settings.blockSize)
        let scale = PRNUAnalyzer.workingScale(width: buffer.width, height: buffer.height, maximumWorkingDimension: settings.maximumWorkingDimension)
        guard buffer.width / scale >= blockSize, buffer.height / scale >= blockSize else {
            return PRNUPresenceAssessment(
                status: .insufficientData("the image is smaller than one \(blockSize)x\(blockSize) px block at working resolution"),
                reliableBlockCount: 0,
                sensorLikeBlockCount: 0,
                medianNoiseLevel: 0
            )
        }

        let luma = PRNUPlane.luminance(of: buffer).downsampled(by: scale)
        var residual = PRNUResidualExtractor.residual(of: luma)
        if scale > 1 {
            // Undo the averaging's noise attenuation, so the fixed
            // per-pixel noise bar means the same thing at every scale.
            residual.values = residual.values.map { $0 * Double(scale) }
        }
        return assess(residual: residual, luma: luma, blockSize: blockSize, minimumReliableBlocks: PRNUAnalyzer.minimumReliableBlocks)
    }

    /// Classifies every non-overlapping `blockSize` block of `residual`
    /// (with matching `luma`, both at working resolution). Partial blocks
    /// at the right and bottom edges are left out, as in the local check.
    /// Reported as insufficient when fewer than `minimumReliableBlocks`
    /// blocks are usable.
    static func assess(residual: PRNUPlane, luma: PRNUPlane, blockSize: Int, minimumReliableBlocks: Int) -> PRNUPresenceAssessment {
        let columns = blockSize > 0 ? residual.width / blockSize : 0
        let rows = blockSize > 0 ? residual.height / blockSize : 0
        guard columns > 0, rows > 0, luma.width == residual.width, luma.height == residual.height else {
            return PRNUPresenceAssessment(
                status: .insufficientData("the image is smaller than one \(blockSize)x\(blockSize) px block"),
                reliableBlockCount: 0,
                sensorLikeBlockCount: 0,
                medianNoiseLevel: 0
            )
        }

        var levels: [Double] = []
        var sensorLike = 0
        for row in 0..<rows {
            for column in 0..<columns {
                let x = column * blockSize
                let y = row * blockSize
                guard PRNULocalConsistency.clippedFraction(luma, x: x, y: y, size: blockSize) <= PRNULocalConsistency.maximumClippedFraction else { continue }
                let signature = PRNUCorrelation.noiseSignature(of: residual, x: x, y: y, size: blockSize)
                levels.append(signature.standardDeviation)
                if isSensorLike(signature) { sensorLike += 1 }
            }
        }

        let status: PRNUPresenceAssessment.Status = levels.count >= max(1, minimumReliableBlocks)
            ? .assessed
            : .insufficientData("only \(levels.count) of \(columns * rows) block(s) aren't clipped to pure black or white, too few to judge")
        return PRNUPresenceAssessment(
            status: status,
            reliableBlockCount: levels.count,
            sensorLikeBlockCount: sensorLike,
            medianNoiseLevel: PRNUCorrelation.median(levels) ?? 0
        )
    }
}
