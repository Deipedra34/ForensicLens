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

    // MARK: - Local statistics

    func testIndexingWrapsAroundBothAxes() throws {
        let size = 8
        let values = (0..<(size * size)).map(Double.init)
        let spectrum = try XCTUnwrap(PowerSpectrum(size: size, values: values))
        XCTAssertEqual(spectrum[-1, 0], spectrum[size - 1, 0])
        XCTAssertEqual(spectrum[0, -1], spectrum[0, size - 1])
        XCTAssertEqual(spectrum[size + 2, 2 * size + 3], spectrum[2, 3])
        XCTAssertEqual(spectrum.wrap(-17), 7)
    }

    func testLocalPeakFindsTheMaximumInItsNeighborhoodAcrossTheEdge() throws {
        let size = 8
        var values = [Double](repeating: 1, count: size * size)
        values[(size - 1) * size + (size - 1)] = 50 // bin (7, 7), adjacent to (0, 0) by wrapping
        let spectrum = try XCTUnwrap(PowerSpectrum(size: size, values: values))
        XCTAssertEqual(spectrum.localPeak(u: 0, v: 0), 50)
        XCTAssertEqual(spectrum.localPeak(u: 0, v: 0, radius: 0), 1)
        XCTAssertEqual(spectrum.localPeak(u: 4, v: 4), 1)
    }

    func testRingMedianIgnoresTheCenterAndOneOutlier() throws {
        let size = 16
        var values = [Double](repeating: 2, count: size * size)
        values[8 * size + 8] = 1_000        // the candidate itself, inside the inner radius
        values[8 * size + 9] = 1_000        // its one-bin spread, also inside
        values[8 * size + 11] = 9_999       // one unrelated strong bin inside the ring
        let spectrum = try XCTUnwrap(PowerSpectrum(size: size, values: values))
        XCTAssertEqual(try XCTUnwrap(spectrum.ringMedian(u: 8, v: 8, innerRadius: 2, outerRadius: 4)), 2)
    }

    func testRingMedianRejectsImpossibleRings() throws {
        let spectrum = try XCTUnwrap(PowerSpectrum(size: 8, values: [Double](repeating: 1, count: 64)))
        XCTAssertNil(spectrum.ringMedian(u: 0, v: 0, innerRadius: 3, outerRadius: 2))
        XCTAssertNil(spectrum.ringMedian(u: 0, v: 0, innerRadius: 1, outerRadius: 4)) // 9 > 8 bins across
        XCTAssertEqual(spectrum.ringMedian(u: 0, v: 0, innerRadius: 1, outerRadius: 3), 1)
    }

    func testWhiteNoiseHasNoBinFarAboveItsLocalBackground() throws {
        let size = 64
        var generator = Fixtures.SeededGenerator(seed: 2024)
        let noise = (0..<(size * size)).map { _ in Fixtures.nextGaussian(&generator) }
        let spectrum = try XCTUnwrap(PowerSpectrum(of: noise, size: size))
        var worst = 0.0
        for v in stride(from: 0, to: size, by: 8) {
            for u in stride(from: 0, to: size, by: 8) where u != 0 || v != 0 {
                let background = try XCTUnwrap(spectrum.ringMedian(u: u, v: v, innerRadius: 2, outerRadius: 4))
                worst = max(worst, spectrum.localPeak(u: u, v: v) / background)
            }
        }
        // Power in a noise bin is exponentially distributed, so a local
        // peak over 9 bins rarely reaches 10x the ring median, never 30x.
        XCTAssertLessThan(worst, 30)
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
