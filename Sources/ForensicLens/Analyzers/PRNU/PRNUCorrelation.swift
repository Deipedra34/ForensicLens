/// The correlation and scoring math PRNU analysis is built on, kept apart
/// from block walking, analyzer glue, and the CLI so every formula here can
/// be unit-tested against small synthetic inputs with known answers.
enum PRNUCorrelation {
    // MARK: - Normalized cross-correlation

    /// Pearson normalized cross-correlation of two equal-length vectors,
    /// from -1 to 1. `nil` when it isn't defined: the vectors differ in
    /// length, are empty, or either one is constant (zero variance), as
    /// happens with the residual of a perfectly uniform image.
    static func normalizedCrossCorrelation(_ a: [Double], _ b: [Double]) -> Double? {
        guard a.count == b.count, !a.isEmpty else { return nil }
        let count = Double(a.count)
        let meanA = a.reduce(0, +) / count
        let meanB = b.reduce(0, +) / count
        var cross = 0.0
        var energyA = 0.0
        var energyB = 0.0
        for i in 0..<a.count {
            let da = a[i] - meanA
            let db = b[i] - meanB
            cross += da * db
            energyA += da * da
            energyB += db * db
        }
        guard energyA > tinyEnergy * count, energyB > tinyEnergy * count else { return nil }
        return max(-1, min(1, cross / (energyA * energyB).squareRoot()))
    }

    /// Per-sample energy below which a signal counts as exactly flat. Far
    /// below anything a real 8-bit image's noise residual produces (even
    /// pure rounding noise has a variance near 1/12), so this only catches
    /// genuinely constant input and floating-point dust.
    static let tinyEnergy = 1e-12

    // MARK: - Block noise signatures

    /// The spatial lags whose correlation coefficients make up a noise
    /// signature: one half of a 5x5 neighborhood, excluding the zero lag.
    /// Lags `(dx, dy)` and `(-dx, -dy)` give the same coefficient, so only
    /// one of each pair is kept. That leaves 12 lags, out to distance 2,
    /// which reaches the period-2 structure color-filter-array
    /// demosaicing leaves in camera noise.
    static let signatureLags: [(dx: Int, dy: Int)] = {
        var lags: [(dx: Int, dy: Int)] = []
        for dy in 0...2 {
            for dx in -2...2 where dy > 0 || dx > 0 {
                lags.append((dx, dy))
            }
        }
        return lags
    }()

    /// A summary of one block's noise residual: how strong it is, and how
    /// it correlates with itself across small spatial lags.
    struct NoiseSignature: Equatable {
        /// Standard deviation of the block's residual about its own mean,
        /// in gray levels.
        let standardDeviation: Double

        /// Correlation coefficient of the residual with itself shifted by
        /// each of `signatureLags`, each from -1 to 1. Uncorrelated (white)
        /// noise gives values near 0; noise that was smoothed, resampled or
        /// interpolated gives clearly positive values at short lags. `nil`
        /// for a block with no measurable residual at all, where the
        /// coefficients are undefined.
        let lagCorrelations: [Double]?
    }

    /// The noise signature of the `size` x `size` block of `residual` at
    /// `(x, y)`. The block must lie inside the plane; a block that doesn't
    /// gives a zero-energy signature rather than reading out of bounds.
    static func noiseSignature(of residual: PRNUPlane, x: Int, y: Int, size: Int) -> NoiseSignature {
        guard size > 2, x >= 0, y >= 0, x + size <= residual.width, y + size <= residual.height else {
            return NoiseSignature(standardDeviation: 0, lagCorrelations: nil)
        }

        var block = [Double](repeating: 0, count: size * size)
        var sum = 0.0
        for row in 0..<size {
            let source = (y + row) * residual.width + x
            for col in 0..<size {
                let value = residual.values[source + col]
                block[row * size + col] = value
                sum += value
            }
        }
        let mean = sum / Double(block.count)
        var energy = 0.0
        for i in 0..<block.count {
            block[i] -= mean
            energy += block[i] * block[i]
        }
        let variance = energy / Double(block.count)
        guard variance > tinyEnergy else {
            return NoiseSignature(standardDeviation: 0, lagCorrelations: nil)
        }

        let correlations = signatureLags.map { lag -> Double in
            var cross = 0.0
            var pairs = 0
            let xStart = max(0, -lag.dx)
            let xEnd = min(size, size - lag.dx)
            for row in 0..<(size - lag.dy) {
                let base = row * size
                let shifted = (row + lag.dy) * size + lag.dx
                for col in xStart..<xEnd {
                    cross += block[base + col] * block[shifted + col]
                    pairs += 1
                }
            }
            guard pairs > 0 else { return 0 }
            return max(-1, min(1, (cross / Double(pairs)) / variance))
        }
        return NoiseSignature(standardDeviation: variance.squareRoot(), lagCorrelations: correlations)
    }

    /// How consistent one block's noise is with the aggregate noise of the
    /// rest of the image, from 0 (nothing alike) to 1 (indistinguishable).
    ///
    /// Two independent agreements are multiplied:
    ///
    /// - **Correlation structure**: `1 - max |rho_block(d) - rho_aggregate(d)|`
    ///   over the signature lags. That's one minus the worst disagreement
    ///   in any single lag correlation coefficient, clamped to 0...1. A
    ///   region pasted in from a source whose noise was smoothed,
    ///   resampled, demosaiced differently or synthesized has a different
    ///   correlation structure, and that difference shows up in at least
    ///   one lag. The worst lag is used rather than an average so that one
    ///   strongly shifted short-lag coefficient isn't diluted by the
    ///   distant lags that barely move. Plain NCC over the signature vector
    ///   was tried first and rejected: any noise is fully correlated with
    ///   itself at lag zero, which dominates the vector and hides even a
    ///   heavily smoothed region.
    /// - **Noise level**: `sqrt(min(sd, aggregateSD) / max(sd, aggregateSD))`.
    ///   A region with no sensor noise at all (a clean synthetic paste, an
    ///   aggressively denoised area) scores near 0. A region whose noise is
    ///   2x off scores about 0.71, so the noise variation that brightness
    ///   alone causes within one honest photo isn't penalized hard. The
    ///   square root keeps level differences from dominating the score.
    ///
    /// A block with no measurable residual scores 0, and so does a block
    /// compared against an aggregate with no measurable residual.
    static func blockConsistency(_ signature: NoiseSignature, aggregateLagCorrelations: [Double]?, aggregateStandardDeviation: Double) -> Double {
        guard let correlations = signature.lagCorrelations,
              let aggregate = aggregateLagCorrelations,
              correlations.count == aggregate.count,
              !correlations.isEmpty,
              signature.standardDeviation > 0,
              aggregateStandardDeviation > 0
        else { return 0 }

        var worst = 0.0
        for i in 0..<correlations.count {
            worst = max(worst, abs(correlations[i] - aggregate[i]))
        }
        let structureAgreement = max(0, 1 - worst)
        let levelRatio = min(signature.standardDeviation, aggregateStandardDeviation) / max(signature.standardDeviation, aggregateStandardDeviation)
        return structureAgreement * levelRatio.squareRoot()
    }

    // MARK: - Leave-one-out aggregation

    /// For every element, the median of all the *other* elements. This is
    /// the "image's own aggregate, excluding this block" each block is
    /// compared against: excluding the block keeps a strongly anomalous
    /// region from pulling its own reference toward itself, and a median
    /// (rather than a mean) keeps a spliced region covering several blocks
    /// from dragging the aggregate either. Sorting once makes it
    /// `O(n log n)` overall. A single-element input has no "others", so its
    /// one result is that element itself.
    static func leaveOneOutMedians(_ values: [Double]) -> [Double] {
        let count = values.count
        guard count > 1 else { return values }

        let order = values.indices.sorted { values[$0] < values[$1] }
        var rank = [Int](repeating: 0, count: count)
        for (position, index) in order.enumerated() { rank[index] = position }
        let sorted = order.map { values[$0] }

        // The remaining n - 1 values, in sorted order, are `sorted` with
        // position `rank[i]` skipped. `element(at:)` reads that sequence.
        let remaining = count - 1
        return (0..<count).map { i in
            let skipped = rank[i]
            func element(at k: Int) -> Double { sorted[k < skipped ? k : k + 1] }
            if remaining % 2 == 1 {
                return element(at: remaining / 2)
            }
            return 0.5 * (element(at: remaining / 2 - 1) + element(at: remaining / 2))
        }
    }

    /// The median of `values`, or `nil` if it's empty.
    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : 0.5 * (sorted[middle - 1] + sorted[middle])
    }

    // MARK: - Peak-to-correlation energy

    /// The result of correlating a noise residual against a reference
    /// pattern: the normalized correlation at zero shift, and the PCE that
    /// measures how far that peak stands above every other shift.
    struct PCEResult: Equatable {
        let peakCorrelation: Double
        let peakToCorrelationEnergy: Double
    }

    /// Peak-to-correlation energy of `residual` against `pattern`, the
    /// standard PRNU camera-matching statistic (Goljan, Fridrich & Filler,
    /// 2009):
    ///
    /// `PCE = sign(rho0) * rho0^2 / mean(rho(s)^2 for s outside a small neighborhood of 0)`
    ///
    /// Here `rho(s)` is the normalized cross-correlation at shift `s` and
    /// `rho0` the value at zero shift, where a matching sensor's pattern
    /// lines up for an image that hasn't been cropped or shifted. Unlike
    /// raw correlation, PCE is normalized by the correlation noise floor of
    /// this particular pair of signals, so one threshold works across image
    /// sizes and content. Shifts within `neighborhoodRadius` of zero are
    /// left out of the floor, since a real peak spreads slightly into its
    /// neighbors.
    ///
    /// Both planes are zero-meaned and then zero-padded up to power-of-two
    /// sizes for the FFT. Padding makes far shifts overlap less signal, so
    /// those shifts contribute slightly smaller values to the floor. The
    /// effect on the result is bounded and the same for matching and
    /// non-matching pairs.
    ///
    /// `nil` if the planes differ in size, are too small to leave any
    /// shifts outside the neighborhood, or either has no measurable energy.
    static func peakToCorrelationEnergy(_ residual: PRNUPlane, _ pattern: PRNUPlane, neighborhoodRadius: Int = 5) -> PCEResult? {
        guard residual.width == pattern.width, residual.height == pattern.height,
              residual.width > 0, residual.height > 0
        else { return nil }

        let paddedWidth = FFT.nextPowerOfTwo(residual.width)
        let paddedHeight = FFT.nextPowerOfTwo(residual.height)
        guard let a = zeroMeanPadded(residual, toWidth: paddedWidth, height: paddedHeight),
              let b = zeroMeanPadded(pattern, toWidth: paddedWidth, height: paddedHeight),
              let correlation = FFT.circularCrossCorrelation(a.values, b.values, width: paddedWidth, height: paddedHeight)
        else { return nil }

        let normalizer = a.norm * b.norm
        let peak = correlation[0] / normalizer

        var floorSum = 0.0
        var floorCount = 0
        for sy in 0..<paddedHeight {
            let distanceY = min(sy, paddedHeight - sy)
            for sx in 0..<paddedWidth {
                let distanceX = min(sx, paddedWidth - sx)
                if distanceX <= neighborhoodRadius && distanceY <= neighborhoodRadius { continue }
                let rho = correlation[sy * paddedWidth + sx] / normalizer
                floorSum += rho * rho
                floorCount += 1
            }
        }
        guard floorCount > 0, floorSum > 0 else { return nil }
        let floor = floorSum / Double(floorCount)
        let pce = (peak < 0 ? -1 : 1) * peak * peak / floor
        return PCEResult(peakCorrelation: max(-1, min(1, peak)), peakToCorrelationEnergy: pce)
    }

    /// `plane` minus its mean, zero-padded into a `width` x `height`
    /// row-major array, plus the original samples' L2 norm. `nil` if that
    /// norm is effectively zero.
    private static func zeroMeanPadded(_ plane: PRNUPlane, toWidth width: Int, height: Int) -> (values: [Double], norm: Double)? {
        let count = plane.values.count
        guard count > 0 else { return nil }
        let mean = plane.values.reduce(0, +) / Double(count)
        var padded = [Double](repeating: 0, count: width * height)
        var energy = 0.0
        for y in 0..<plane.height {
            for x in 0..<plane.width {
                let value = plane.values[y * plane.width + x] - mean
                padded[y * width + x] = value
                energy += value * value
            }
        }
        guard energy > tinyEnergy * Double(count) else { return nil }
        return (padded, energy.squareRoot())
    }
}
