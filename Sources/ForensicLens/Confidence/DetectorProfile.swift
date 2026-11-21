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

    public init(analyzerID: String, family: EvidenceFamily, scoreCeiling: Double, localizes: Bool) {
        self.analyzerID = analyzerID
        self.family = family
        self.scoreCeiling = scoreCeiling
        self.localizes = localizes
    }

    /// The built-in detectors, in the engine's run order.
    public static let builtIn: [DetectorProfile] = [
        DetectorProfile(analyzerID: "ela", family: .compressionHistory, scoreCeiling: 100, localizes: true),
        DetectorProfile(analyzerID: "metadata", family: .metadata, scoreCeiling: 100, localizes: false),
        DetectorProfile(analyzerID: "clone", family: .duplication, scoreCeiling: 100, localizes: true),
        DetectorProfile(analyzerID: "doublecompression", family: .compressionHistory, scoreCeiling: 100, localizes: false),
        DetectorProfile(analyzerID: "prnu", family: .sensorNoise, scoreCeiling: 100, localizes: true),
        DetectorProfile(analyzerID: "cfa", family: .demosaicing, scoreCeiling: 100, localizes: true),
        DetectorProfile(analyzerID: "jpegghost", family: .compressionHistory, scoreCeiling: 100, localizes: true),
        DetectorProfile(analyzerID: "thumbnail", family: .thumbnail, scoreCeiling: 90, localizes: true),
        DetectorProfile(analyzerID: "aigenerated", family: .generation, scoreCeiling: 75, localizes: false),
        DetectorProfile(analyzerID: "noiselevel", family: .sensorNoise, scoreCeiling: 80, localizes: true),
    ]

    /// The profile for `analyzerID`. An analyzer without one (a custom
    /// analyzer added by a library user) gets a neutral profile: its own
    /// family, a 0-100 scale, and no localization.
    public static func profile(for analyzerID: String) -> DetectorProfile {
        builtIn.first { $0.analyzerID == analyzerID }
            ?? DetectorProfile(analyzerID: analyzerID, family: .other, scoreCeiling: 100, localizes: false)
    }
}
