import XCTest
import ImageDecoding
@testable import ForensicLens

/// End-to-end coverage of the noise-level consistency check on synthetic
/// images (see `NoiseLevelFixtures.swift`): a smoothed block and a noisier
/// block spliced into an otherwise uniformly noisy image must be exactly
/// the blocks flagged, each with the right direction. An untouched image,
/// and a flat, clipped, tiny, or undecoded one, must produce no false
/// finding and no crash.
final class NoiseLevelAnalyzerTests: XCTestCase {
    /// 5x5 blocks at the default 64px block size.
    private let size = 320
    private let sigma = 3.0
    private let smoothRegion = Region(x: 128, y: 64, width: 64, height: 64)
    private let noisyRegion = Region(x: 192, y: 192, width: 64, height: 64)

    private func untouched(channels: Int = 1) throws -> PixelBuffer {
        try Fixtures.noiseLevelImage(width: size, height: size, sigma: sigma, channels: channels)
    }

    private func spliced(channels: Int = 1) throws -> PixelBuffer {
        try Fixtures.noiseLevelImage(width: size, height: size, sigma: sigma, channels: channels, splices: [
            (smoothRegion, .blurred(radius: 2)),
            (noisyRegion, .noise(sigma: 4 * sigma, seed: 99)),
        ])
    }

    private func map(_ buffer: PixelBuffer, settings: ForensicLensConfig.NoiseLevelConfig = .default) throws -> NoiseLevelMap {
        try XCTUnwrap(NoiseLevelAnalyzer.noiseLevelMap(for: buffer, settings: settings))
    }

    private func analyze(_ buffer: PixelBuffer, config: ForensicLensConfig = .default) throws -> AnalyzerFinding {
        try NoiseLevelAnalyzer().analyze(Fixtures.imageData(from: buffer), config: config)
    }

    // MARK: - Untouched image

    func testUntouchedImageIsConsistentEverywhere() throws {
        let map = try map(untouched())
        XCTAssertEqual(map.columns, 5)
        XCTAssertEqual(map.rows, 5)
        XCTAssertEqual(map.blocks.count, 25)
        XCTAssertTrue(map.flaggedBlocks.isEmpty, "\(map.flaggedBlocks.map(\.region))")
        XCTAssertEqual(map.typicalSigma, sigma, accuracy: sigma * 0.1, "8-bit rounding adds a little")
        for block in map.blocks {
            XCTAssertEqual(try XCTUnwrap(block.ratio), 1, accuracy: 0.2)
        }

        let finding = try analyze(untouched())
        XCTAssertEqual(finding.analyzerID, "noiselevel")
        XCTAssertEqual(finding.score, 0)
        XCTAssertTrue(finding.summary.contains("consistent across all 25"), finding.summary)
    }

    // MARK: - Spliced image

    func testSmoothedAndNoisierBlocksAreFlaggedInTheRightDirection() throws {
        let map = try map(spliced())
        let flagged = map.flaggedBlocks
        XCTAssertEqual(Set(flagged.map(\.region)), [smoothRegion, noisyRegion])

        let smooth = try XCTUnwrap(flagged.first { $0.region == smoothRegion })
        XCTAssertEqual(smooth.status, .tooSmooth)
        XCTAssertEqual(smooth.direction, .tooSmooth)
        XCTAssertLessThan(try XCTUnwrap(smooth.ratio), 0.5)
        XCTAssertFalse(smooth.exposureExplained, "same brightness as its surroundings")

        let noisy = try XCTUnwrap(flagged.first { $0.region == noisyRegion })
        XCTAssertEqual(noisy.status, .tooNoisy)
        XCTAssertEqual(noisy.direction, .tooNoisy)
        XCTAssertGreaterThan(try XCTUnwrap(noisy.ratio), 2)
        XCTAssertFalse(noisy.exposureExplained)

        // The splices don't move the baseline: it's still the image's own noise.
        XCTAssertEqual(map.typicalSigma, sigma, accuracy: sigma * 0.1)
    }

    func testSplicedFindingReportsBothDirectionsAndTheirRegions() throws {
        let finding = try analyze(spliced())
        XCTAssertGreaterThan(finding.score, 20)
        XCTAssertLessThanOrEqual(finding.score, 80, "a supporting signal is capped below the other detectors")
        XCTAssertTrue(finding.summary.contains("1 too smooth"), finding.summary)
        XCTAssertTrue(finding.summary.contains("1 too noisy"), finding.summary)

        let smoothSummary = try XCTUnwrap(finding.indicators.first { $0.message.contains("too smooth:") })
        XCTAssertEqual(smoothSummary.regions, [smoothRegion])
        let noisySummary = try XCTUnwrap(finding.indicators.first { $0.message.contains("too noisy:") })
        XCTAssertEqual(noisySummary.regions, [noisyRegion])

        // One per-block indicator each, pointing at the same blocks.
        let blockIndicators = finding.indicators.filter { $0.message.hasPrefix("Block at") }
        XCTAssertEqual(Set(blockIndicators.flatMap(\.regions)), [smoothRegion, noisyRegion])
    }

    func testColorImagesAreMeasuredOnLuma() throws {
        let map = try map(spliced(channels: 3))
        XCTAssertEqual(Set(map.flaggedBlocks.map(\.region)), [smoothRegion, noisyRegion])
        XCTAssertTrue(try self.map(untouched(channels: 3)).flaggedBlocks.isEmpty)
    }

    func testOnlyTheSmoothSpliceWithJustOneDirection() throws {
        let buffer = try Fixtures.noiseLevelImage(width: size, height: size, sigma: sigma, splices: [(smoothRegion, .blurred(radius: 2))])
        let finding = try analyze(buffer)
        XCTAssertTrue(finding.summary.contains("(1 too smooth)"), finding.summary)
        XCTAssertFalse(finding.indicators.contains { $0.message.contains("too noisy") })
    }

    // MARK: - Config knobs

    func testThresholdsControlEachDirectionSeparately() throws {
        // Noise of a third of the image's: a ratio of about 0.35.
        let buffer = try Fixtures.noiseLevelImage(width: size, height: size, sigma: sigma, splices: [
            (smoothRegion, .noise(sigma: sigma / 3, seed: 5)),
            (noisyRegion, .noise(sigma: 4 * sigma, seed: 99)),
        ])
        let quieter = try XCTUnwrap(try map(buffer).blocks.first { $0.region == smoothRegion })
        XCTAssertEqual(try XCTUnwrap(quieter.ratio), 0.35, accuracy: 0.05)
        XCTAssertEqual(Set(try map(buffer).flaggedBlocks.map(\.region)), [smoothRegion, noisyRegion])

        var settings = ForensicLensConfig.NoiseLevelConfig.default
        settings.smoothThreshold = 0.25
        XCTAssertEqual(try map(buffer, settings: settings).flaggedBlocks.map(\.region), [noisyRegion])

        settings = .default
        settings.noisyThreshold = 6 // the noisy block has ~4x
        XCTAssertEqual(try map(buffer, settings: settings).flaggedBlocks.map(\.region), [smoothRegion])
    }

    func testBlockSizeIsRaisedToTheMinimum() {
        XCTAssertEqual(NoiseLevelAnalyzer.effectiveBlockSize(4), 16)
        XCTAssertEqual(NoiseLevelAnalyzer.effectiveBlockSize(17), 17)
        XCTAssertEqual(NoiseLevelAnalyzer.effectiveBlockSize(64), 64)
    }

    func testSmallerBlocksLocalizeTheSameSplices() throws {
        var settings = ForensicLensConfig.NoiseLevelConfig.default
        settings.blockSize = 32
        let flagged = try map(spliced(), settings: settings).flaggedBlocks
        // Each 64px splice is four 32px blocks.
        XCTAssertEqual(flagged.filter { $0.direction == .tooSmooth }.count, 4)
        XCTAssertEqual(flagged.filter { $0.direction == .tooNoisy }.count, 4)
        for block in flagged {
            XCTAssertNotNil(block.region.intersection(block.direction == .tooSmooth ? smoothRegion : noisyRegion))
        }
    }

    // MARK: - Degenerate inputs

    func testUniformColorImageIsNotAssessed() throws {
        let finding = try analyze(Fixtures.uniformBuffer(width: size, height: size))
        XCTAssertEqual(finding.score, 0)
        XCTAssertTrue(finding.summary.contains("No measurable noise"), finding.summary)
        XCTAssertTrue(finding.summary.contains("low confidence"), finding.summary)

        let map = try map(Fixtures.uniformBuffer(width: size, height: size))
        XCTAssertFalse(map.noiseMeasurable)
        XCTAssertTrue(map.flaggedBlocks.isEmpty)
        XCTAssertTrue(map.blocks.allSatisfy { $0.status == .unreliable && $0.sigma == 0 })
    }

    func testImageTooSmallToBlockIsNotAssessed() throws {
        let tiny = try Fixtures.noiseLevelImage(width: 100, height: 100, sigma: sigma)
        XCTAssertNil(NoiseLevelAnalyzer.noiseLevelMap(for: tiny, settings: .default))
        let finding = try analyze(tiny)
        XCTAssertEqual(finding.score, 0)
        XCTAssertTrue(finding.summary.contains("too small"), finding.summary)
        XCTAssertTrue(finding.summary.contains("low confidence"), finding.summary)

        // Even smaller than one residual window: no crash either.
        XCTAssertEqual(try analyze(Fixtures.uniformBuffer(width: 2, height: 2)).score, 0)
    }

    func testMostlyClippedImageIsNotAssessed() throws {
        let white = try Fixtures.uniformBuffer(width: size, height: size, value: 255)
        let finding = try analyze(white)
        XCTAssertEqual(finding.score, 0)
        XCTAssertTrue(finding.summary.contains("clipped"), finding.summary)
    }

    func testClippedBlocksAreSkippedNotFlaggedAsSmooth() throws {
        var pixels = try untouched().pixels
        // Blow out one block to pure white.
        for y in 0..<64 {
            for x in 256..<320 {
                pixels[y * size + x] = 255
            }
        }
        let map = try map(PixelBuffer(width: size, height: size, channels: 1, pixels: pixels))
        let blownOut = try XCTUnwrap(map.blocks.first { $0.region == Region(x: 256, y: 0, width: 64, height: 64) })
        XCTAssertEqual(blownOut.status, .unreliable)
        XCTAssertNil(blownOut.sigma)
        XCTAssertTrue(map.flaggedBlocks.isEmpty)
    }

    func testImageWithoutDecodedPixelsThrowsUnsupportedInput() throws {
        let image = try ImageData.load(Fixtures.jpegBytesWithNoExif())
        XCTAssertThrowsError(try NoiseLevelAnalyzer().analyze(image, config: .default)) { error in
            guard case AnalyzerError.unsupportedInput = error else {
                return XCTFail("expected unsupportedInput, got \(error)")
            }
        }
    }
}
