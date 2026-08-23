import XCTest
import ForensicLens
import ImageDecoding

final class MetadataAnalyzerTests: XCTestCase {
    func testCleanCameraExifProducesNoIndicators() throws {
        let bytes = Fixtures.jpegBytes(
            make: "Canon",
            model: "EOS 90D",
            dateTime: "2024:03:10 14:22:00",
            dateTimeOriginal: "2024:03:10 14:20:05",
            dateTimeDigitized: "2024:03:10 14:20:05",
            // Present and consistent with DateTimeOriginal, so the
            // GPS-vs-camera-info and GPS-timestamp cross-field checks both
            // stay quiet -- this fixture is meant to read as a genuinely
            // unremarkable, internally-consistent capture.
            gpsDateTimeUTC: "2024:03:10 14:20:05"
        )
        let image = try ImageData.load(bytes)

        let finding = try MetadataAnalyzer().analyze(image, config: .default)

        XCTAssertEqual(finding.score, 0)
        XCTAssertTrue(finding.indicators.isEmpty)
    }

    func testEditingSoftwareSignatureIsFlagged() throws {
        let bytes = Fixtures.jpegBytes(
            make: "Canon",
            model: "EOS 90D",
            software: "Adobe Photoshop 25.0",
            dateTime: "2024:03:10 14:22:00",
            dateTimeOriginal: "2024:03:10 14:20:05"
        )
        let image = try ImageData.load(bytes)

        let finding = try MetadataAnalyzer().analyze(image, config: .default)

        XCTAssertGreaterThan(finding.score, 0)
        XCTAssertTrue(finding.indicators.contains { $0.message.lowercased().contains("photoshop") })
    }

    func testModifiedBeforeOriginalIsFlaggedAsImpossible() throws {
        let bytes = Fixtures.jpegBytes(
            dateTime: "2020:01:01 00:00:00",
            dateTimeOriginal: "2024:03:10 14:20:05"
        )
        let image = try ImageData.load(bytes)

        let finding = try MetadataAnalyzer().analyze(image, config: .default)

        XCTAssertGreaterThanOrEqual(finding.score, 50)
        XCTAssertTrue(finding.indicators.contains { $0.message.lowercased().contains("not possible") })
    }

    func testLargeTimestampDriftIsFlagged() throws {
        var config = ForensicLensConfig.default
        config.metadata.maxTimestampDriftSeconds = 60 * 60 * 24 // 1 day

        let bytes = Fixtures.jpegBytes(
            dateTime: "2024:06:01 00:00:00",
            dateTimeOriginal: "2024:01:01 00:00:00"
        )
        let image = try ImageData.load(bytes)

        let finding = try MetadataAnalyzer().analyze(image, config: config)

        XCTAssertGreaterThan(finding.score, 0)
    }

    func testImageWithNoExifIsCleanByDefault() throws {
        let bytes = Fixtures.jpegBytesWithNoExif()
        let image = try ImageData.load(bytes)

        let finding = try MetadataAnalyzer().analyze(image, config: .default)

        XCTAssertEqual(finding.score, 0)
    }

    func testMissingExifCanBeFlaggedWhenConfigured() throws {
        var config = ForensicLensConfig.default
        config.metadata.flagMissingExif = true

        let bytes = Fixtures.jpegBytesWithNoExif()
        let image = try ImageData.load(bytes)

        let finding = try MetadataAnalyzer().analyze(image, config: config)

        XCTAssertGreaterThan(finding.score, 0)
    }

    func testMissingMakeAndModelIsFlaggedAsMildIndicator() throws {
        let bytes = Fixtures.jpegBytes(dateTimeOriginal: "2024:01:01 00:00:00")
        let image = try ImageData.load(bytes)

        let finding = try MetadataAnalyzer().analyze(image, config: .default)

        XCTAssertTrue(finding.indicators.contains { $0.message.lowercased().contains("make/model") })
    }

    func testNonJPEGFormatIsSkippedCleanly() throws {
        let buffer = try Fixtures.uniformBuffer(width: 8, height: 8)
        let image = try Fixtures.imageData(from: buffer)

        let finding = try MetadataAnalyzer().analyze(image, config: .default)

        XCTAssertEqual(finding.score, 0)
        XCTAssertTrue(finding.indicators.isEmpty)
    }

    // MARK: - Cross-field: GPS timestamp vs. DateTimeOriginal

    func testGPSTimestampFarFromDateTimeOriginalIsFlagged() throws {
        let bytes = Fixtures.jpegBytes(
            make: "Apple",
            model: "iPhone 13",
            dateTimeOriginal: "2024:03:10 14:20:05",
            gpsDateTimeUTC: "2024:03:10 15:10:05" // 50 minutes off, well beyond the 5-minute default
        )
        let image = try ImageData.load(bytes)

        let finding = try MetadataAnalyzer().analyze(image, config: .default)

        XCTAssertTrue(finding.indicators.contains {
            $0.message.lowercased().contains("gps timestamp") && $0.message.lowercased().contains("differ by")
        })
    }

    func testGPSTimestampCloseToDateTimeOriginalIsNotFlagged() throws {
        let bytes = Fixtures.jpegBytes(
            make: "Apple",
            model: "iPhone 13",
            dateTimeOriginal: "2024:03:10 14:20:05",
            gpsDateTimeUTC: "2024:03:10 14:22:00" // under 2 minutes off, within the 5-minute default
        )
        let image = try ImageData.load(bytes)

        let finding = try MetadataAnalyzer().analyze(image, config: .default)

        XCTAssertFalse(finding.indicators.contains { $0.message.lowercased().contains("gps timestamp") })
    }

    func testGPSTimestampCheckSkippedWhenGPSTimestampMissing() throws {
        // Only one of the two compared fields (DateTimeOriginal) is
        // present, so there is nothing to cross-check.
        let bytes = Fixtures.jpegBytes(
            make: "Apple",
            model: "iPhone 13",
            dateTimeOriginal: "2024:03:10 14:20:05"
        )
        let image = try ImageData.load(bytes)

        let finding = try MetadataAnalyzer().analyze(image, config: .default)

        XCTAssertFalse(finding.indicators.contains { $0.message.lowercased().contains("gps timestamp") })
    }

    // MARK: - Cross-field: DateTimeDigitized vs. DateTimeOriginal

    func testDigitizedDateFarFromOriginalIsFlagged() throws {
        let bytes = Fixtures.jpegBytes(
            dateTimeOriginal: "2024:03:10 14:20:05",
            dateTimeDigitized: "2024:03:10 15:00:00" // 40 minutes off, well beyond the 5-minute default
        )
        let image = try ImageData.load(bytes)

        let finding = try MetadataAnalyzer().analyze(image, config: .default)

        XCTAssertTrue(finding.indicators.contains { $0.message.lowercased().contains("datetimedigitized") })
    }

    func testDigitizedDateCloseToOriginalIsNotFlagged() throws {
        let bytes = Fixtures.jpegBytes(
            dateTimeOriginal: "2024:03:10 14:20:05",
            dateTimeDigitized: "2024:03:10 14:20:10" // 5 seconds off, within the 5-minute default
        )
        let image = try ImageData.load(bytes)

        let finding = try MetadataAnalyzer().analyze(image, config: .default)

        XCTAssertFalse(finding.indicators.contains { $0.message.lowercased().contains("datetimedigitized") })
    }

    func testDigitizedDriftCheckSkippedWhenDigitizedMissing() throws {
        // Only DateTimeOriginal is present, so there is nothing to
        // cross-check against DateTimeDigitized.
        let bytes = Fixtures.jpegBytes(dateTimeOriginal: "2024:03:10 14:20:05")
        let image = try ImageData.load(bytes)

        let finding = try MetadataAnalyzer().analyze(image, config: .default)

        XCTAssertFalse(finding.indicators.contains { $0.message.lowercased().contains("datetimedigitized") })
    }

    // MARK: - Cross-field: partial metadata stripping (GPS vs. Make/Model)

    func testGPSPresentWithoutCameraInfoIsFlaggedAsPartialStripping() throws {
        let bytes = Fixtures.jpegBytes(gpsDateTimeUTC: "2024:03:10 14:20:05")
        let image = try ImageData.load(bytes)

        let finding = try MetadataAnalyzer().analyze(image, config: .default)

        XCTAssertTrue(finding.indicators.contains { $0.message.lowercased().contains("make/model is missing") })
    }

    func testCameraInfoWithoutGPSIsFlaggedAsPartialStripping() throws {
        let bytes = Fixtures.jpegBytes(make: "Canon", model: "EOS 90D")
        let image = try ImageData.load(bytes)

        let finding = try MetadataAnalyzer().analyze(image, config: .default)

        XCTAssertTrue(finding.indicators.contains { $0.message.lowercased().contains("no gps location data was recorded") })
    }

    func testGPSAndCameraInfoTogetherIsNotFlaggedAsPartialStripping() throws {
        let bytes = Fixtures.jpegBytes(
            make: "Apple",
            model: "iPhone 13",
            dateTimeOriginal: "2024:03:10 14:20:05",
            gpsDateTimeUTC: "2024:03:10 14:20:30"
        )
        let image = try ImageData.load(bytes)

        let finding = try MetadataAnalyzer().analyze(image, config: .default)

        XCTAssertFalse(finding.indicators.contains { $0.message.lowercased().contains("make/model is missing") })
        XCTAssertFalse(finding.indicators.contains { $0.message.lowercased().contains("no gps location data was recorded") })
    }

    // MARK: - Cross-field: GPS altitude sign vs. GPSAltitudeRef

    func testNegativeGPSAltitudeWithAboveSeaLevelRefIsFlagged() throws {
        let bytes = Fixtures.jpegBytes(gpsAltitude: -50, gpsAltitudeRef: 0) // 0 = above sea level -- contradicts the negative value
        let image = try ImageData.load(bytes)

        let finding = try MetadataAnalyzer().analyze(image, config: .default)

        XCTAssertTrue(finding.indicators.contains {
            $0.message.lowercased().contains("gpsaltitude") && $0.message.lowercased().contains("does not indicate")
        })
    }

    func testNegativeGPSAltitudeWithBelowSeaLevelRefIsNotFlagged() throws {
        let bytes = Fixtures.jpegBytes(gpsAltitude: -50, gpsAltitudeRef: 1) // 1 = below sea level -- consistent with the negative value
        let image = try ImageData.load(bytes)

        let finding = try MetadataAnalyzer().analyze(image, config: .default)

        XCTAssertFalse(finding.indicators.contains { $0.message.lowercased().contains("gpsaltitude") })
    }

    func testGPSAltitudeCheckSkippedWhenAltitudeRefMissing() throws {
        // Only GPSAltitude is present, so there is no GPSAltitudeRef to
        // cross-check it against.
        let bytes = Fixtures.jpegBytes(gpsAltitude: -50)
        let image = try ImageData.load(bytes)

        let finding = try MetadataAnalyzer().analyze(image, config: .default)

        XCTAssertFalse(finding.indicators.contains { $0.message.lowercased().contains("gpsaltitude") })
    }

    // MARK: - Cross-field: editing software + unedited-camera-original claim

    func testEditingSoftwareWithUnchangedModifyDateIsFlaggedAsUneditedClaimConflict() throws {
        let bytes = Fixtures.jpegBytes(
            make: "Canon",
            model: "EOS 90D",
            software: "Adobe Photoshop 25.0",
            dateTime: "2024:03:10 14:20:05",
            dateTimeOriginal: "2024:03:10 14:20:05" // identical to ModifyDate -- claims no re-save ever happened
        )
        let image = try ImageData.load(bytes)

        let finding = try MetadataAnalyzer().analyze(image, config: .default)

        XCTAssertTrue(finding.indicators.contains { $0.message.lowercased().contains("unedited camera-original identity") })
    }

    func testEditingSoftwareWithChangedModifyDateIsNotFlaggedAsUneditedClaimConflict() throws {
        let bytes = Fixtures.jpegBytes(
            make: "Canon",
            model: "EOS 90D",
            software: "Adobe Photoshop 25.0",
            dateTime: "2024:03:10 14:25:00", // ModifyDate moved, consistent with actually having been re-saved
            dateTimeOriginal: "2024:03:10 14:20:05"
        )
        let image = try ImageData.load(bytes)

        let finding = try MetadataAnalyzer().analyze(image, config: .default)

        XCTAssertFalse(finding.indicators.contains { $0.message.lowercased().contains("unedited camera-original identity") })
    }

    func testEditingSoftwareConflictCheckSkippedWhenCameraIdentityMissing() throws {
        // Only Software (and the two timestamps) are present, so there is
        // no camera Make/Model identity to cross-check against.
        let bytes = Fixtures.jpegBytes(
            software: "Adobe Photoshop 25.0",
            dateTime: "2024:03:10 14:20:05",
            dateTimeOriginal: "2024:03:10 14:20:05"
        )
        let image = try ImageData.load(bytes)

        let finding = try MetadataAnalyzer().analyze(image, config: .default)

        XCTAssertFalse(finding.indicators.contains { $0.message.lowercased().contains("unedited camera-original identity") })
    }
}
