import XCTest
@testable import ForensicLens

/// Covers the thumbnail-vs-main-image comparison on its own, with small
/// synthetic planes whose expected results are known: resampling,
/// letterbox trimming, aspect ratios, and the similarity score.
final class ThumbnailSimilarityTests: XCTestCase {
    private func texture(width: Int, height: Int, seed: UInt64) -> PRNUPlane {
        var generator = Fixtures.SeededGenerator(seed: seed)
        return PRNUPlane(width: width, height: height, values: (0..<(width * height)).map { _ in Double(generator.nextByte()) })
    }

    // MARK: - Resampling

    func testResampleAveragesWholeAndPartialSamples() {
        let plane = PRNUPlane(width: 4, height: 4, values: (0..<16).map(Double.init))
        XCTAssertEqual(ThumbnailSimilarity.resample(plane, toWidth: 2, height: 2).values, [2.5, 4.5, 10.5, 12.5])

        // 3 -> 2 samples: each output covers one and a half inputs.
        let row = PRNUPlane(width: 3, height: 1, values: [0, 3, 6])
        let halved = ThumbnailSimilarity.resample(row, toWidth: 2, height: 1).values
        XCTAssertEqual(halved[0], 1, accuracy: 1e-12) // (0 * 1 + 3 * 0.5) / 1.5
        XCTAssertEqual(halved[1], 5, accuracy: 1e-12) // (3 * 0.5 + 6 * 1) / 1.5

        XCTAssertEqual(ThumbnailSimilarity.resample(PRNUPlane(width: 1, height: 1, values: [7]), toWidth: 2, height: 2).values, [7, 7, 7, 7])
    }

    // MARK: - Letterbox and aspect ratio

    func testLetterboxAndPillarboxBarsAreTrimmed() {
        var plane = texture(width: 12, height: 12, seed: 1)
        for x in 0..<12 {
            plane[x, 0] = 0
            plane[x, 11] = 3
        }
        for y in 0..<12 { plane[0, y] = 1 }
        XCTAssertEqual(ThumbnailSimilarity.contentRegion(of: plane), Region(x: 1, y: 1, width: 11, height: 10))
    }

    func testDarkContentIsNotTrimmedPastAQuarter() {
        let black = PRNUPlane(width: 16, height: 16, repeating: 0)
        let region = ThumbnailSimilarity.contentRegion(of: black)
        XCTAssertEqual(region, Region(x: 4, y: 4, width: 8, height: 8))
    }

    func testAspectRatioDifference() {
        XCTAssertEqual(ThumbnailSimilarity.aspectRatioDifference(width: 160, height: 120, otherWidth: 4000, otherHeight: 3000), 0, accuracy: 1e-12)
        XCTAssertEqual(ThumbnailSimilarity.aspectRatioDifference(width: 16, height: 9, otherWidth: 4, otherHeight: 3), log((16.0 / 9) / (4.0 / 3)), accuracy: 1e-12)
        XCTAssertEqual(ThumbnailSimilarity.aspectRatioDifference(width: 4, height: 3, otherWidth: 16, otherHeight: 9), log((16.0 / 9) / (4.0 / 3)), accuracy: 1e-12, "symmetric")
    }

    func testCenteredRegionWithAspect() {
        XCTAssertEqual(ThumbnailSimilarity.centeredRegion(withAspect: 16, 9, in: Region(x: 0, y: 0, width: 64, height: 48)), Region(x: 0, y: 6, width: 64, height: 36))
        XCTAssertEqual(ThumbnailSimilarity.centeredRegion(withAspect: 4, 3, in: Region(x: 0, y: 0, width: 64, height: 36)), Region(x: 8, y: 0, width: 48, height: 36))
    }

    // MARK: - Similarity

    func testIdenticalImagesScoreOne() throws {
        let plane = texture(width: 32, height: 24, seed: 2)
        let result = try XCTUnwrap(ThumbnailSimilarity.compare(plane, plane))
        XCTAssertEqual(result.similarity, 1, accuracy: 1e-9)
        XCTAssertEqual(result.cellsCompared, 16)
    }

    func testBrightnessAndContrastChangesDontMatter() throws {
        let plane = texture(width: 32, height: 24, seed: 3)
        let adjusted = PRNUPlane(width: 32, height: 24, values: plane.values.map { 0.5 * $0 + 40 })
        XCTAssertEqual(try XCTUnwrap(ThumbnailSimilarity.compare(plane, adjusted)).similarity, 1, accuracy: 1e-9)
    }

    func testUnrelatedImagesScoreLow() throws {
        let result = try XCTUnwrap(ThumbnailSimilarity.compare(texture(width: 32, height: 24, seed: 4), texture(width: 32, height: 24, seed: 5)))
        XCTAssertLessThan(abs(result.global ?? 1), 0.2)
        XCTAssertLessThan(result.similarity, 0.2)
    }

    func testOneChangedCellIsFoundAndLocated() throws {
        let original = texture(width: 32, height: 24, seed: 6)
        var edited = original
        let other = texture(width: 8, height: 6, seed: 7)
        for y in 0..<6 { for x in 0..<8 { edited[16 + x, 6 + y] = other[x, y] } }

        let result = try XCTUnwrap(ThumbnailSimilarity.compare(edited, original))
        XCTAssertGreaterThan(result.global ?? 0, 0.8, "one cell barely moves the global score")
        XCTAssertLessThan(result.worstCell ?? 1, 0.3)
        XCTAssertEqual(result.worstCellRegion, Region(x: 16, y: 6, width: 8, height: 6))
        XCTAssertEqual(result.similarity, result.worstCell ?? 1, accuracy: 1e-12)
    }

    func testDetailAgainstAFlatAreaScoresZero() throws {
        let textured = texture(width: 16, height: 16, seed: 8)
        let flat = PRNUPlane(width: 16, height: 16, repeating: 120)
        XCTAssertEqual(try XCTUnwrap(ThumbnailSimilarity.compare(textured, flat)).similarity, 0)
    }

    func testNothingToCompare() {
        let flat = PRNUPlane(width: 16, height: 16, repeating: 90)
        XCTAssertNil(ThumbnailSimilarity.compare(flat, flat), "both featureless")
        XCTAssertNil(ThumbnailSimilarity.compare(texture(width: 16, height: 16, seed: 9), texture(width: 8, height: 16, seed: 9)), "different sizes")
    }
}
