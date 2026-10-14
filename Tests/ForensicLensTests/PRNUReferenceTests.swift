import XCTest
import ImageDecoding
@testable import ForensicLens
@testable import forensiclens_cli

/// Covers PRNU reference-fingerprint mode: building a fingerprint from a
/// handful of synthetic captures through one simulated sensor, verifying
/// that another capture through that sensor matches while a capture through
/// a different sensor scores lower, every way building or verifying can go
/// wrong (too few images, mismatched sizes, no noise, unreadable files),
/// and the `--reference` CLI option.
final class PRNUReferenceTests: XCTestCase {
    private let size = 128
    private let referenceSensorSeed: UInt64 = 11
    private let otherSensorSeed: UInt64 = 12

    private func captures(sensorSeed: UInt64, scenes: ClosedRange<Int>, width: Int? = nil, height: Int? = nil) throws -> [PixelBuffer] {
        let width = width ?? size
        let height = height ?? size
        let sensor = Fixtures.sensorPattern(width: width, height: height, seed: sensorSeed)
        return try scenes.map { scene in
            try Fixtures.simulatedCapture(width: width, height: height, sensor: sensor, sceneSeed: scene, noiseSeed: 200 + UInt64(scene))
        }
    }

    /// Five references from the reference sensor: "a handful", under
    /// `recommendedImageCount`, so results are flagged as low confidence.
    private func fingerprint() throws -> PRNUReferenceFingerprint {
        try PRNUReferenceFingerprint.build(from: captures(sensorSeed: referenceSensorSeed, scenes: 1...5), maximumWorkingDimension: 2048)
    }

    /// A new scene through the reference sensor, and the same scene through
    /// a different sensor.
    private func referenceTestCaptures() throws -> (sameCamera: PixelBuffer, otherCamera: PixelBuffer) {
        let same = try Fixtures.simulatedCapture(
            width: size, height: size,
            sensor: Fixtures.sensorPattern(width: size, height: size, seed: referenceSensorSeed),
            sceneSeed: 9, noiseSeed: 300
        )
        let other = try Fixtures.simulatedCapture(
            width: size, height: size,
            sensor: Fixtures.sensorPattern(width: size, height: size, seed: otherSensorSeed),
            sceneSeed: 9, noiseSeed: 301
        )
        return (same, other)
    }

    // MARK: - Verification

    func testSameCameraMatchesAndDifferentCameraScoresLower() throws {
        let reference = try fingerprint()
        XCTAssertEqual(reference.imageCount, 5)
        XCTAssertEqual(reference.analysisRegion, Region(x: 0, y: 0, width: size, height: size))

        let (same, other) = try referenceTestCaptures()
        let match = reference.verify(same)
        let mismatch = reference.verify(other)

        XCTAssertEqual(match.outcome, .match)
        XCTAssertEqual(mismatch.outcome, .mismatch)
        let matchPCE = try XCTUnwrap(match.peakToCorrelationEnergy)
        let mismatchPCE = try XCTUnwrap(mismatch.peakToCorrelationEnergy)
        XCTAssertGreaterThanOrEqual(matchPCE, PRNUReferenceFingerprint.matchThreshold)
        XCTAssertLessThan(mismatchPCE, PRNUReferenceFingerprint.matchThreshold)
        XCTAssertGreaterThan(matchPCE, mismatchPCE * 10)
        XCTAssertGreaterThan(try XCTUnwrap(match.peakCorrelation), try XCTUnwrap(mismatch.peakCorrelation))
        XCTAssertTrue(match.isLowConfidence, "5 references is below the recommended 10")
    }

    func testAnalyzerScoresAMismatchedCameraAsMoreSuspicious() throws {
        let analyzer = PRNUAnalyzer(reference: try fingerprint())
        let (same, other) = try referenceTestCaptures()

        let matchFinding = try analyzer.analyze(Fixtures.imageData(from: same), config: .default)
        let mismatchFinding = try analyzer.analyze(Fixtures.imageData(from: other), config: .default)

        XCTAssertEqual(matchFinding.score, 0)
        XCTAssertTrue(matchFinding.summary.contains("matches the reference fingerprint built from 5 image(s)"), matchFinding.summary)
        XCTAssertTrue(matchFinding.summary.contains("low confidence"), matchFinding.summary)

        XCTAssertGreaterThan(mismatchFinding.score, matchFinding.score)
        XCTAssertTrue(mismatchFinding.summary.contains("does not match"), mismatchFinding.summary)
        let indicator = try XCTUnwrap(mismatchFinding.indicators.last)
        XCTAssertEqual(indicator.regions, [Region(x: 0, y: 0, width: size, height: size)])
        XCTAssertGreaterThan(indicator.weight, 0)
    }

    func testEngineUsesTheSuppliedFingerprint() throws {
        let engine = ForensicLensEngine(config: .default, prnuReference: try fingerprint())
        let report = engine.run(on: try Fixtures.imageData(from: referenceTestCaptures().otherCamera), only: ["prnu"])
        let finding = try XCTUnwrap(report.findings.first)
        XCTAssertEqual(finding.analyzerID, "prnu")
        XCTAssertGreaterThan(report.overallScore, 0)
    }

    func testDifferentlySizedImageIsSkippedNotMisjudged() throws {
        let reference = try fingerprint()
        let small = try Fixtures.simulatedCapture(
            width: 64, height: 64,
            sensor: Fixtures.sensorPattern(width: 64, height: 64, seed: referenceSensorSeed),
            sceneSeed: 9, noiseSeed: 302
        )
        XCTAssertEqual(reference.verify(small).outcome, .dimensionMismatch)

        let finding = try PRNUAnalyzer(reference: reference).analyze(Fixtures.imageData(from: small), config: .default)
        XCTAssertEqual(finding.score, 0)
        XCTAssertTrue(finding.summary.contains("skipped"), finding.summary)
    }

    func testNoiselessImageIsInconclusive() throws {
        let reference = try fingerprint()
        let flat = try Fixtures.uniformBuffer(width: size, height: size, channels: 1, value: 120)
        let verification = reference.verify(flat)
        XCTAssertEqual(verification.outcome, .noMeasurableNoise)
        XCTAssertNil(verification.peakToCorrelationEnergy)
    }

    func testLargeReferenceImagesUseACentralNativeResolutionCrop() {
        XCTAssertEqual(
            PRNUReferenceFingerprint.analysisRegion(width: 4000, height: 3000, maximumWorkingDimension: 2048),
            Region(x: 976, y: 476, width: 2048, height: 2048)
        )
        XCTAssertEqual(
            PRNUReferenceFingerprint.analysisRegion(width: 300, height: 200, maximumWorkingDimension: 2048),
            Region(x: 0, y: 0, width: 300, height: 200)
        )
    }

    // MARK: - Building errors

    func testTooFewReferenceImagesIsAnError() throws {
        let one = try captures(sensorSeed: referenceSensorSeed, scenes: 1...1)
        XCTAssertThrowsError(try PRNUReferenceFingerprint.build(from: one, maximumWorkingDimension: 2048)) { error in
            XCTAssertEqual(error as? PRNUReferenceError, .tooFewImages(found: 1, required: 2))
            XCTAssertTrue("\(error)".contains("at least 2"), "\(error)")
        }
        XCTAssertThrowsError(try PRNUReferenceFingerprint.build(from: [], maximumWorkingDimension: 2048)) { error in
            XCTAssertEqual(error as? PRNUReferenceError, .tooFewImages(found: 0, required: 2))
        }
    }

    func testReferenceImagesOfDifferentSizesAreAnError() throws {
        let first = try captures(sensorSeed: referenceSensorSeed, scenes: 1...1)
        let narrower = try captures(sensorSeed: referenceSensorSeed, scenes: 2...2, width: 96)
        XCTAssertThrowsError(try PRNUReferenceFingerprint.build(from: first + narrower, labels: ["a.pgm", "b.pgm"], maximumWorkingDimension: 2048)) { error in
            XCTAssertEqual(error as? PRNUReferenceError, .mismatchedDimensions(image: "b.pgm", width: 96, height: 128, expectedWidth: 128, expectedHeight: 128))
            XCTAssertTrue("\(error)".contains("b.pgm"), "\(error)")
        }
    }

    func testNoiselessReferenceImagesAreAnError() throws {
        let flat = try Fixtures.uniformBuffer(width: 64, height: 64, channels: 1, value: 100)
        XCTAssertThrowsError(try PRNUReferenceFingerprint.build(from: [flat, flat, flat], maximumWorkingDimension: 2048)) { error in
            XCTAssertEqual(error as? PRNUReferenceError, .noMeasurableNoise)
        }
    }

    // MARK: - Loading from a folder

    func testLoadingAFolderSkipsNonImagesAndFolders() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for (index, buffer) in try captures(sensorSeed: referenceSensorSeed, scenes: 1...3).enumerated() {
            try Data(ImageEncoder.encodePPM(buffer)).write(to: root.appendingPathComponent("ref-\(index).pgm"))
        }
        try Data("not an image".utf8).write(to: root.appendingPathComponent("notes.txt"))
        try Data("junk".utf8).write(to: root.appendingPathComponent(".DS_Store"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: true)

        let reference = try PRNUReferenceFingerprint.load(fromFolder: root.path, maximumWorkingDimension: 2048)
        XCTAssertEqual(reference.imageCount, 3)
        XCTAssertEqual(reference.imageWidth, size)
    }

    func testFolderWithAnUndecodableImageIsAnError() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for (index, buffer) in try captures(sensorSeed: referenceSensorSeed, scenes: 1...2).enumerated() {
            try Data(ImageEncoder.encodePPM(buffer)).write(to: root.appendingPathComponent("ref-\(index).pgm"))
        }
        try Data(Fixtures.jpegBytesWithNoExif()).write(to: root.appendingPathComponent("photo.jpg"))

        XCTAssertThrowsError(try PRNUReferenceFingerprint.load(fromFolder: root.path, maximumWorkingDimension: 2048)) { error in
            guard case PRNUReferenceError.undecodableImage(let image, _)? = error as? PRNUReferenceError else {
                return XCTFail("expected undecodableImage, got \(error)")
            }
            XCTAssertEqual(image, "photo.jpg")
        }
    }

    func testMissingFolderIsAnError() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("forensiclens-prnu-missing-\(UUID().uuidString)").path
        XCTAssertThrowsError(try PRNUReferenceFingerprint.load(fromFolder: missing, maximumWorkingDimension: 2048)) { error in
            XCTAssertEqual(error as? PRNUReferenceError, .folderNotFound(missing))
        }
    }

    func testLoadIfConfiguredOnlyLoadsWhenEnabledWithAFolder() throws {
        XCTAssertNil(try PRNUReferenceFingerprint.loadIfConfigured(.default))
        var disabled = ForensicLensConfig.PRNUConfig.default
        disabled.enabled = false
        disabled.referenceFolder = "/does/not/exist"
        XCTAssertNil(try PRNUReferenceFingerprint.loadIfConfigured(disabled))
    }

    // MARK: - CLI

    func testReferenceOptionSetsTheConfiguredFolder() throws {
        let parsed = CLI.ParsedArguments(positionals: ["photo.ppm"], flags: [], options: ["--reference": "camera-refs"])
        let config = try CLI.applyingReferenceOption(parsed, to: .default)
        XCTAssertEqual(config.prnu.referenceFolder, "camera-refs")

        var expected = ForensicLensConfig.default
        expected.prnu.referenceFolder = "camera-refs"
        XCTAssertEqual(config, expected, "nothing else in the config changes")

        let without = CLI.ParsedArguments(positionals: ["photo.ppm"], flags: [], options: [:])
        XCTAssertEqual(try CLI.applyingReferenceOption(without, to: .default), .default)
    }

    func testReferenceOptionErrors() {
        let missingValue = CLI.ParsedArguments(positionals: ["photo.ppm"], flags: ["--reference"], options: [:])
        XCTAssertThrowsError(try CLI.applyingReferenceOption(missingValue, to: .default))

        var disabled = ForensicLensConfig.default
        disabled.prnu.enabled = false
        let parsed = CLI.ParsedArguments(positionals: ["photo.ppm"], flags: [], options: ["--reference": "camera-refs"])
        XCTAssertThrowsError(try CLI.applyingReferenceOption(parsed, to: disabled)) { error in
            XCTAssertTrue("\(error)".contains("disabled"), "\(error)")
        }
    }

    func testReferenceIsOnlyBuiltWhenPRNURuns() throws {
        var config = ForensicLensConfig.default
        config.prnu.referenceFolder = "/does/not/exist"
        XCTAssertNil(try CLI.loadPRNUReference(for: config, running: ["ela"]), "an ELA-only run never touches the reference folder")
        XCTAssertThrowsError(try CLI.loadPRNUReference(for: config, running: nil))
    }

    func testPRNUCommandWithReferenceRunsEndToEnd() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let referenceFolder = root.appendingPathComponent("refs", isDirectory: true)
        try FileManager.default.createDirectory(at: referenceFolder, withIntermediateDirectories: true)
        for (index, buffer) in try captures(sensorSeed: referenceSensorSeed, scenes: 1...4).enumerated() {
            try Data(ImageEncoder.encodePPM(buffer)).write(to: referenceFolder.appendingPathComponent("ref-\(index).pgm"))
        }
        let imagePath = root.appendingPathComponent("photo.pgm").path
        try Data(ImageEncoder.encodePPM(referenceTestCaptures().sameCamera)).write(to: URL(fileURLWithPath: imagePath))
        let noConfig = root.appendingPathComponent("does-not-exist.yaml").path

        let ok = await CLI.run(arguments: ["forensiclens-cli", "prnu", imagePath, "--reference", referenceFolder.path, "--json", "--config", noConfig])
        XCTAssertEqual(ok, 0)

        let missing = await CLI.run(arguments: ["forensiclens-cli", "prnu", imagePath, "--reference", root.appendingPathComponent("nope").path, "--config", noConfig])
        XCTAssertEqual(missing, 1, "a reference folder that can't be loaded is a clear error, not a silent skip")
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("forensiclens-prnu-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
