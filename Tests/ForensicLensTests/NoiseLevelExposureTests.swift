import XCTest
import ImageDecoding
@testable import ForensicLens

/// How the noise-level check behaves on untouched images whose brightness
/// varies, the case it's most prone to false positives on. A camera's
/// noise has two parts: read noise, the same everywhere, and photon shot
/// noise, whose standard deviation grows with the square root of
/// brightness. Nothing in these images is edited, so every flagged block
/// is a false positive; the tests pin down when that happens and how much
/// it's allowed to count.
final class NoiseLevelExposureTests: XCTestCase {
    private let size = 320

    /// Shot-noise-dominated sensor: sigma = 0.35 * sqrt(brightness).
    private let shotNoise: (Double) -> Double = { 0.35 * $0.squareRoot() }

    private func map(_ buffer: PixelBuffer) throws -> NoiseLevelMap {
        try XCTUnwrap(NoiseLevelAnalyzer.noiseLevelMap(for: buffer, settings: .default))
    }

    private func analyze(_ buffer: PixelBuffer) throws -> AnalyzerFinding {
        try NoiseLevelAnalyzer().analyze(Fixtures.imageData(from: buffer), config: .default)
    }

    func testBrightnessAloneIsNotNoise() throws {
        // Very different exposures, the same read noise: the high-pass
        // residual ignores the brightness itself.
        let bands = try Fixtures.exposureBandsImage(width: size, height: size, levels: [40, 100, 160, 220], noise: { _ in 3 })
        XCTAssertTrue(try map(bands).flaggedBlocks.isEmpty)
        XCTAssertEqual(try analyze(bands).score, 0)
    }

    func testModerateExposureDifferencesWithShotNoiseAreTolerated() throws {
        // Shadows to highlights spanning about 2.3x in brightness: noise
        // varies by about 1.5x, inside the default 0.5 / 2.0 thresholds.
        let bands = try Fixtures.exposureBandsImage(width: size, height: size, levels: [80, 110, 140, 180], noise: shotNoise)
        let map = try map(bands)
        XCTAssertTrue(map.flaggedBlocks.isEmpty, "\(map.flaggedBlocks.map(\.region))")
        XCTAssertEqual(try analyze(bands).score, 0)
    }

    func testWidelyVaryingNoiseWidensTheCutoffsInsteadOfFlagging() throws {
        // A high-dynamic-range scene (brightness 12 to 240) under shot noise:
        // block noise levels span about 0.4x to 2x the median. Because so
        // many blocks vary, the robust spread widens the cutoffs well past
        // the configured 0.5 / 2.0, and nothing is flagged.
        let bands = try Fixtures.exposureBandsImage(width: size, height: size, levels: [12, 30, 120, 240], noise: shotNoise)
        let map = try map(bands)
        XCTAssertTrue(map.flaggedBlocks.isEmpty)
        XCTAssertLessThan(map.smoothCutoff, 0.5)
        XCTAssertGreaterThan(map.noisyCutoff, 2.0)
        XCTAssertEqual(try analyze(bands).score, 0)
    }

    func testTheWidenedCutoffsAlsoCostSensitivity() throws {
        // The price of that tolerance: in the same HDR scene, a mid-tone
        // block re-noised at a quarter of its expected level is no longer
        // caught, while the same splice in an evenly lit scene is.
        let blockRegion = Region(x: 128, y: 128, width: 64, height: 64)
        func scene(_ level: @escaping (Int, Int) -> Double) throws -> PixelBuffer {
            try Fixtures.exposureImage(width: size, height: size, level: level, noise: { base in
                0.35 * base.squareRoot()
            })
        }
        func withQuietBlock(_ buffer: PixelBuffer) throws -> PixelBuffer {
            var pixels = buffer.pixels
            var generator = Fixtures.SeededGenerator(seed: 21)
            for y in blockRegion.y..<(blockRegion.y + blockRegion.height) {
                for x in blockRegion.x..<(blockRegion.x + blockRegion.width) {
                    let value = 120 + 0.25 * 0.35 * 120.0.squareRoot() * Fixtures.nextGaussian(&generator)
                    pixels[y * size + x] = UInt8(clamping: Int(value.rounded()))
                }
            }
            return try PixelBuffer(width: size, height: size, channels: 1, pixels: pixels)
        }

        let even = try withQuietBlock(scene { _, _ in 120 })
        XCTAssertEqual(try map(even).flaggedBlocks.map(\.region), [blockRegion])

        let hdrLevels: [Double] = [12, 30, 120, 240, 120]
        let hdr = try withQuietBlock(scene { _, y in hdrLevels[min(4, y / 64)] })
        XCTAssertFalse(try map(hdr).flaggedBlocks.contains { $0.region == blockRegion })
    }

    func testANaturalShadowInAnEvenlyLitSceneIsALowWeightFalsePositive() throws {
        // The case the check gets wrong: one deep shadow (brightness ~15) in
        // an otherwise evenly lit scene (~150). Its shot noise is about a
        // third of the rest, so it's flagged as too smooth -- but its
        // brightness accounts for that, so it's marked as exposure-explained
        // and barely moves the score.
        let shadow = Region(x: 64, y: 192, width: 64, height: 64)
        let buffer = try Fixtures.exposureImage(width: size, height: size, level: { x, y in
            shadow.intersection(Region(x: x, y: y, width: 1, height: 1)) != nil ? 15 : 150
        }, noise: shotNoise)

        let flagged = try map(buffer).flaggedBlocks
        XCTAssertEqual(flagged.map(\.region), [shadow])
        let block = try XCTUnwrap(flagged.first)
        XCTAssertEqual(block.direction, .tooSmooth)
        XCTAssertTrue(block.exposureExplained)

        let finding = try analyze(buffer)
        XCTAssertGreaterThan(finding.score, 0)
        XCTAssertLessThan(finding.score, 20, "stays in the 'likely authentic' range on its own")
        XCTAssertTrue(finding.indicators.contains { $0.message.contains("could account for this on its own") })

        // A splice of the same size and direction at ordinary brightness
        // counts for much more.
        let splice = try Fixtures.noiseLevelImage(width: size, height: size, sigma: 0.35 * 150.0.squareRoot(), splices: [
            (shadow, .noise(sigma: 0.35 * 15.0.squareRoot(), seed: 8)),
        ])
        let spliceFinding = try analyze(splice)
        XCTAssertGreaterThan(spliceFinding.score, 2 * finding.score)
    }
}
