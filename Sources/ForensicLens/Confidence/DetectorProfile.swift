/// The kind of trace a detector measures. Detectors in the same family look
/// at the same underlying evidence, so when they agree it isn't independent
/// corroboration: ELA, JPEG ghost detection, and double-compression
/// detection all read the image's JPEG compression history, and PRNU and the
/// noise-level check both read its sensor noise.
public enum EvidenceFamily: String, Sendable, Codable, CaseIterable {
    case compressionHistory
    case sensorNoise
    case demosaicing
    case duplication
    case metadata
    case thumbnail
    case generation
    case other
}

/// What confidence calibration needs to know about one detector, keyed by
/// its analyzer identifier.
public struct DetectorProfile: Sendable, Equatable {
    public let analyzerID: String

    /// The trace this detector measures; see `EvidenceFamily`.
    public let family: EvidenceFamily

    /// The highest score this detector can produce by construction. Raw
    /// scores are divided by it (see `ScoreNormalizer`), because detectors
    /// don't share one scale: the noise-level check tops out at 80, the
    /// AI-generated image check at 75, the thumbnail check at 90, and the
    /// rest at 100.
    public let scoreCeiling: Double

    /// Whether this detector's regions point at a specific part of the
    /// image. Only those take part in region agreement; double-compression
    /// detection, metadata, and the AI-generated image check describe the
    /// whole file.
    public let localizes: Bool

    /// How much a finding from this detector counts, from 0 to 1, after
    /// normalization: a detector's strongest possible finding contributes
    /// exactly this much evidence on its own. Lower for detectors whose own
    /// documentation lists common innocent causes, so they can raise the
    /// calibrated confidence but not carry it alone.
    public let reliability: Double

    /// Why `reliability` has its value, citing the detector's documented
    /// false-positive causes. Shown in the README's calibration table.
    public let reliabilityNote: String

    public init(analyzerID: String, family: EvidenceFamily, scoreCeiling: Double, localizes: Bool, reliability: Double, reliabilityNote: String) {
        self.analyzerID = analyzerID
        self.family = family
        self.scoreCeiling = scoreCeiling
        self.localizes = localizes
        self.reliability = min(1, max(0, reliability))
        self.reliabilityNote = reliabilityNote
    }

    /// Reliability given to analyzers without a built-in profile: counted,
    /// but never more than a middling detector.
    public static let defaultReliability = 0.5

    /// The built-in detectors, in the engine's run order. Reliability, from
    /// most to least: clone 0.95, thumbnail 0.85, PRNU and JPEG ghost 0.8,
    /// CFA 0.7, double compression 0.65, ELA and metadata 0.6, AI-generated
    /// image check 0.5, noise-level check 0.4.
    public static let builtIn: [DetectorProfile] = [
        DetectorProfile(
            analyzerID: "ela", family: .compressionHistory, scoreCeiling: 100, localizes: true, reliability: 0.6,
            reliabilityNote: "High-contrast edges, text, and fine texture also have elevated error levels in untouched JPEGs."
        ),
        DetectorProfile(
            analyzerID: "metadata", family: .metadata, scoreCeiling: 100, localizes: false, reliability: 0.6,
            reliabilityNote: "Editing software and re-saved timestamps are just as common in innocent exports (cropping, resizing) as in manipulation."
        ),
        DetectorProfile(
            analyzerID: "clone", family: .duplication, scoreCeiling: 100, localizes: true, reliability: 0.95,
            reliabilityNote: "An exact block match or a geometrically verified keypoint match rarely happens by chance; repeating patterns are the main innocent cause."
        ),
        DetectorProfile(
            analyzerID: "doublecompression", family: .compressionHistory, scoreCeiling: 100, localizes: false, reliability: 0.65,
            reliabilityNote: "Shows the file was saved twice, which every edit does but so does any innocent re-save; it doesn't say where or what changed."
        ),
        DetectorProfile(
            analyzerID: "prnu", family: .sensorNoise, scoreCeiling: 100, localizes: true, reliability: 0.8,
            reliabilityNote: "Dark, clipped, and strongly textured areas are its documented source of false positives."
        ),
        DetectorProfile(
            analyzerID: "cfa", family: .demosaicing, scoreCeiling: 100, localizes: true, reliability: 0.7,
            reliabilityNote: "Recompression, resizing, and phone computational-photography pipelines weaken the pattern unevenly; documented as a supporting signal."
        ),
        DetectorProfile(
            analyzerID: "jpegghost", family: .compressionHistory, scoreCeiling: 100, localizes: true, reliability: 0.8,
            reliabilityNote: "A different compression quality in one region rarely arises innocently, but needs JPEG-derived pixels and is blind to coarser re-saves."
        ),
        DetectorProfile(
            analyzerID: "thumbnail", family: .thumbnail, scoreCeiling: 90, localizes: true, reliability: 0.85,
            reliabilityNote: "A thumbnail that no longer matches is strong evidence the picture changed after capture; benign re-exporters and rotations are the innocent causes."
        ),
        DetectorProfile(
            analyzerID: "aigenerated", family: .generation, scoreCeiling: 75, localizes: false, reliability: 0.5,
            reliabilityNote: "Not a trained classifier: JPEG grids, resampling, screenshots, and graphics can trip its signals."
        ),
        DetectorProfile(
            analyzerID: "noiselevel", family: .sensorNoise, scoreCeiling: 80, localizes: true, reliability: 0.4,
            reliabilityNote: "Documented as more false-positive-prone than PRNU: exposure, texture, defocus, and smooth surfaces all change noise in untouched photos."
        ),
    ]

    /// The profile for `analyzerID`. An analyzer without one (a custom
    /// analyzer added by a library user) gets a neutral profile: its own
    /// family, a 0-100 scale, no localization, and `defaultReliability`.
    public static func profile(for analyzerID: String) -> DetectorProfile {
        builtIn.first { $0.analyzerID == analyzerID }
            ?? DetectorProfile(analyzerID: analyzerID, family: .other, scoreCeiling: 100, localizes: false,
                               reliability: defaultReliability, reliabilityNote: "No built-in profile; counted at a middling weight.")
    }

    /// `finding`'s weighted evidence on the common 0...1 scale: its
    /// normalized strength (see `ScoreNormalizer`) times this detector's
    /// reliability.
    public func weightedEvidence(normalizedStrength: Double) -> Double {
        normalizedStrength * reliability
    }
}
