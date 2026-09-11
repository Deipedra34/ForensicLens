import XCTest
import ForensicLens

final class ConfigTests: XCTestCase {
    func testParsingOverridesDefaultsOnlyForMentionedKeys() throws {
        let yaml = """
        ela:
          elaQualityLevels: [50]
        """
        let config = try ConfigLoader.parse(yaml)

        XCTAssertEqual(config.ela.elaQualityLevels, [50])
        // Untouched keys, including in an untouched section, should still
        // match the package defaults.
        XCTAssertEqual(config.ela.errorThreshold, ForensicLensConfig.default.ela.errorThreshold)
        XCTAssertEqual(config.metadata, ForensicLensConfig.default.metadata)
        XCTAssertEqual(config.cloneDetection, ForensicLensConfig.default.cloneDetection)
    }

    func testParsingAllThreeSections() throws {
        let yaml = """
        # Full override of every section.
        ela:
          enabled: false
          elaQualityLevels: [40, 60]
          errorThreshold: 15.5
          flaggedRegionFraction: 0.02

        metadata:
          enabled: true
          flagMissingExif: true
          suspiciousSoftwareKeywords: [gimp, "photoshop"]
          maxTimestampDriftSeconds: 3600

        cloneDetection:
          enabled: false
          blockSize: 32
          blockStride: 16
          minimumBlockVariance: 10
          similarityThreshold: 4.5
          minimumBlockDistance: 40
        """
        let config = try ConfigLoader.parse(yaml)

        XCTAssertEqual(config.ela.enabled, false)
        XCTAssertEqual(config.ela.elaQualityLevels, [40, 60])
        XCTAssertEqual(config.ela.errorThreshold, 15.5)
        XCTAssertEqual(config.ela.flaggedRegionFraction, 0.02)

        XCTAssertEqual(config.metadata.enabled, true)
        XCTAssertEqual(config.metadata.flagMissingExif, true)
        XCTAssertEqual(config.metadata.suspiciousSoftwareKeywords, ["gimp", "photoshop"])
        XCTAssertEqual(config.metadata.maxTimestampDriftSeconds, 3600)

        XCTAssertEqual(config.cloneDetection.enabled, false)
        XCTAssertEqual(config.cloneDetection.blockSize, 32)
        XCTAssertEqual(config.cloneDetection.blockStride, 16)
        XCTAssertEqual(config.cloneDetection.minimumBlockVariance, 10)
        XCTAssertEqual(config.cloneDetection.similarityThreshold, 4.5)
        XCTAssertEqual(config.cloneDetection.minimumBlockDistance, 40)
    }

    func testMissingConfigFileFallsBackToDefaults() throws {
        let config = try ConfigLoader.load(contentsOfFile: "/this/path/definitely/does/not/exist.yaml")
        XCTAssertEqual(config, ForensicLensConfig.default)
    }

    func testUnknownKeyThrows() {
        let yaml = """
        ela:
          notARealKey: 1
        """
        XCTAssertThrowsError(try ConfigLoader.parse(yaml)) { error in
            guard case ConfigError.unknownKey(let section, let key) = error else {
                return XCTFail("Expected ConfigError.unknownKey, got \(error)")
            }
            XCTAssertEqual(section, "ela")
            XCTAssertEqual(key, "notARealKey")
        }
    }

    func testInvalidValueThrows() {
        let yaml = """
        ela:
          qualityLevel: not-a-number
        """
        XCTAssertThrowsError(try ConfigLoader.parse(yaml)) { error in
            guard case ConfigError.invalidValue(let key, let value) = error else {
                return XCTFail("Expected ConfigError.invalidValue, got \(error)")
            }
            XCTAssertEqual(key, "qualityLevel")
            XCTAssertEqual(value, "not-a-number")
        }
    }

    func testKeyOutsideAnySectionThrows() {
        let yaml = "qualityLevel: 50"
        XCTAssertThrowsError(try ConfigLoader.parse(yaml)) { error in
            guard case ConfigError.malformedLine(_, _) = error else {
                return XCTFail("Expected ConfigError.malformedLine, got \(error)")
            }
        }
    }

    func testCommentsAndBlankLinesAreIgnored() throws {
        let yaml = """
        # a leading comment

        ela:
          # a nested comment
          elaQualityLevels: [60]

          errorThreshold: 20 # trailing comment
        """
        let config = try ConfigLoader.parse(yaml)

        XCTAssertEqual(config.ela.elaQualityLevels, [60])
        XCTAssertEqual(config.ela.errorThreshold, 20)
    }

    func testDefaultConfigIsInternallyConsistent() {
        let config = ForensicLensConfig.default
        XCTAssertTrue(config.ela.enabled)
        XCTAssertTrue(config.metadata.enabled)
        XCTAssertTrue(config.cloneDetection.enabled)
        XCTAssertFalse(config.ela.elaQualityLevels.isEmpty)
        for level in config.ela.elaQualityLevels {
            XCTAssertGreaterThan(level, 0)
            XCTAssertLessThanOrEqual(level, 100)
        }
    }

    // MARK: - Backward-compatible single-value quality config

    /// The old config shape (pre-multi-quality ELA) used a single scalar
    /// `qualityLevel` key. `ConfigLoader` still accepts it as an alias for
    /// `elaQualityLevels`, wrapping the scalar into a one-element list, so
    /// an old `forensiclens.yaml` doesn't fail to parse after this upgrade.
    func testLegacyQualityLevelKeyParsesAsOneElementList() throws {
        let yaml = """
        ela:
          qualityLevel: 55
        """
        let config = try ConfigLoader.parse(yaml)

        XCTAssertEqual(config.ela.elaQualityLevels, [55])
    }

    /// `elaQualityLevels` itself also accepts a bare scalar (not just the
    /// `[a, b, c]` list form), for the same reason: someone hand-editing
    /// the new key while still thinking in single-quality terms shouldn't
    /// get a parse error.
    func testElaQualityLevelsAcceptsBareScalar() throws {
        let yaml = """
        ela:
          elaQualityLevels: 65
        """
        let config = try ConfigLoader.parse(yaml)

        XCTAssertEqual(config.ela.elaQualityLevels, [65])
    }
}
