import XCTest
@testable import ForensicLens

/// Covers `PowerSpectrum`, the shared frequency-domain utility, with small
/// synthetic planes whose spectra are known analytically: pure tones,
/// constant planes, and white noise.
final class PowerSpectrumTests: XCTestCase {
    // MARK: - Helpers

    /// A `size` x `size` plane holding `cos(2 * pi * (u * x + v * y) / size)`,
    /// a single tone that sits exactly on bin `(u, v)` (and its mirror).
    private func tone(size: Int, u: Int, v: Int, amplitude: Double = 1) -> [Double] {
        var plane = [Double](repeating: 0, count: size * size)
        for y in 0..<size {
            for x in 0..<size {
                plane[y * size + x] = amplitude * cos(2 * Double.pi * Double(u * x + v * y) / Double(size))
            }
        }
        return plane
    }

    private func strongestBin(_ spectrum: PowerSpectrum) -> (u: Int, v: Int) {
        var best = 0
        for i in 1..<spectrum.values.count where spectrum.values[i] > spectrum.values[best] {
            best = i
        }
        return (best % spectrum.size, best / spectrum.size)
    }

    // MARK: - Construction

    func testRejectsNonPowerOfTwoAndMismatchedSizes() {
        XCTAssertNil(PowerSpectrum(of: [Double](repeating: 0, count: 36), size: 6))
        XCTAssertNil(PowerSpectrum(of: [Double](repeating: 0, count: 15), size: 4))
        XCTAssertNil(PowerSpectrum(of: [1], size: 1))
        XCTAssertNil(PowerSpectrum(of: [], size: 0))
        XCTAssertNil(PowerSpectrum(size: 4, values: [Double](repeating: 0, count: 8)))
    }

    func testConstantPlaneHasNoPower() throws {
        let spectrum = try XCTUnwrap(PowerSpectrum(of: [Double](repeating: 137, count: 64), size: 8))
        XCTAssertEqual(spectrum.values.max() ?? -1, 0, accuracy: 1e-18)
        XCTAssertEqual(spectrum.meanNonZeroFrequencyPower, 0, accuracy: 1e-18)
    }

    // MARK: - Pure tones

    func testUnwindowedOnBinToneConcentratesInItsBinAndMirror() throws {
        let size = 32
        let spectrum = try XCTUnwrap(PowerSpectrum(of: tone(size: size, u: 5, v: 3), size: size, windowed: false))
        // A real cosine of amplitude 1 puts (N^2 / 2)^2 into each of its two
        // conjugate bins and nothing anywhere else.
        let expected = pow(Double(size * size) / 2, 2)
        XCTAssertEqual(spectrum[5, 3], expected, accuracy: expected * 1e-9)
        XCTAssertEqual(spectrum[-5, -3], expected, accuracy: expected * 1e-9)
        let total = spectrum.values.reduce(0, +)
        XCTAssertEqual(total, 2 * expected, accuracy: expected * 1e-9)
    }

    func testWindowedToneStaysWithinOneBinOfItsFrequency() throws {
        let size = 64
        let spectrum = try XCTUnwrap(PowerSpectrum(of: tone(size: size, u: 16, v: 8), size: size))
        let peak = strongestBin(spectrum)
        XCTAssertTrue(peak == (16, 8) || peak == (size - 16, size - 8), "peak at \(peak)")

        // The periodic Hann window spreads an on-bin tone over at most one
        // bin each side, so two bins away there's essentially nothing.
        XCTAssertLessThan(spectrum[18, 8], spectrum[16, 8] * 1e-20 + 1e-12)
        XCTAssertLessThan(spectrum[16, 10], spectrum[16, 8] * 1e-20 + 1e-12)
        XCTAssertGreaterThan(spectrum[17, 8], 0)
    }

    func testNyquistCheckerboardPeaksAtTheCorner() throws {
        let size = 16
        let checkerboard = (0..<(size * size)).map { i -> Double in
            ((i % size) + (i / size)) % 2 == 0 ? 1 : -1
        }
        let spectrum = try XCTUnwrap(PowerSpectrum(of: checkerboard, size: size, windowed: false))
        let peak = strongestBin(spectrum)
        XCTAssertEqual(peak.u, size / 2)
        XCTAssertEqual(peak.v, size / 2)
    }

    func testMeanIsRemovedBeforeTransforming() throws {
        let size = 16
        let offset = tone(size: size, u: 2, v: 0).map { $0 + 500 }
        let spectrum = try XCTUnwrap(PowerSpectrum(of: offset, size: size, windowed: false))
        XCTAssertEqual(spectrum[0, 0], 0, accuracy: 1e-6)
    }

    // MARK: - Hann window

    func testHannWindowShape() {
        let window = PowerSpectrum.hannWindow(size: 8)
        XCTAssertEqual(window.count, 8)
        XCTAssertEqual(window[0], 0, accuracy: 1e-15)
        XCTAssertEqual(window[4], 1, accuracy: 1e-15)
        XCTAssertEqual(window[2], window[6], accuracy: 1e-15)
        XCTAssertEqual(PowerSpectrum.hannWindow(size: 0), [])
    }
}
