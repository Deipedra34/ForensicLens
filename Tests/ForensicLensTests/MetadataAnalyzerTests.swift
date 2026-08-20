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
            dateTimeDigitized: "2024:03:10 14:20:05"
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
}
