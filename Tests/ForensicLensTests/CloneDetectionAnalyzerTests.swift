import XCTest
import ForensicLens
import ImageDecoding

final class CloneDetectionAnalyzerTests: XCTestCase {
    func testUniformImageHasNoClonableRegions() throws {
        let buffer = try Fixtures.uniformBuffer(width: 96, height: 96)
        let image = try Fixtures.imageData(from: buffer)

        let finding = try CloneDetectionAnalyzer().analyze(image, config: .default)

        // Every block is flat, so the minimum-variance filter should reject
        // all of them before any pairwise comparison even happens. A
        // uniform image should never come back "manipulated."
        XCTAssertEqual(finding.score, 0)
        XCTAssertTrue(finding.indicators.isEmpty)
    }

    func testDuplicatedPatchIsDetected() throws {
        let base = try Fixtures.noiseBuffer(width: 128, height: 128, seed: 42)
        let withClone = try Fixtures.pastingPatch(of: 24, from: (x: 8, y: 8), to: (x: 90, y: 90), into: base)
        let image = try Fixtures.imageData(from: withClone)

        let finding = try CloneDetectionAnalyzer().analyze(image, config: .default)

        XCTAssertGreaterThan(finding.score, 0)
        XCTAssertFalse(finding.indicators.isEmpty)
    }

    func testDistinctNoiseRegionsAreNotFalselyMatched() throws {
        // Two different seeds should produce blocks that look nothing
        // alike, so no matches should surface even though both halves are
        // high-variance (and therefore pass the flatness filter).
        var pixels = try Fixtures.noiseBuffer(width: 64, height: 32, seed: 1).pixels
        let secondHalf = try Fixtures.noiseBuffer(width: 64, height: 32, seed: 99).pixels
        pixels.append(contentsOf: secondHalf)
        let buffer = try PixelBuffer(width: 64, height: 64, channels: 3, pixels: pixels)
        let image = try Fixtures.imageData(from: buffer)

        var config = ForensicLensConfig.default
        config.cloneDetection.similarityThreshold = 2 // strict, to avoid coincidental noise matches

        let finding = try CloneDetectionAnalyzer().analyze(image, config: config)

        XCTAssertEqual(finding.score, 0)
    }

    func testImageSmallerThanBlockSizeIsHandledGracefully() throws {
        let buffer = try Fixtures.noiseBuffer(width: 4, height: 4)
        let image = try Fixtures.imageData(from: buffer)

        let finding = try CloneDetectionAnalyzer().analyze(image, config: .default)

        XCTAssertEqual(finding.score, 0)
    }

    func testThrowsUnsupportedInputWhenPixelsAreUnavailable() throws {
        let bytes = Fixtures.jpegBytesWithNoExif()
        let image = try ImageData.load(bytes)

        XCTAssertThrowsError(try CloneDetectionAnalyzer().analyze(image, config: .default)) { error in
            guard case AnalyzerError.unsupportedInput(_) = error else {
                return XCTFail("Expected AnalyzerError.unsupportedInput, got \(error)")
            }
        }
    }
}
