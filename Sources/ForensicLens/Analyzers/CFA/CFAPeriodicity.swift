import Foundation

/// The periodicity math behind CFA consistency analysis, kept apart from
/// block walking, analyzer glue, and the CLI so every formula can be
/// unit-tested on small synthetic grids with known answers.
///
/// A Bayer sensor records one color per pixel site: green on one
/// checkerboard (quincunx) half of the sites, red and blue each on one
/// quarter, in a 2x2 repeating layout. Demosaicing fills in the two
/// missing colors at every site by interpolating from neighbors. The
/// interpolated samples are therefore close to a linear combination of
/// their neighbors, while the recorded ones carry the scene's (and the
/// sensor's) full, unpredictable detail.
///
/// This exploits that directly, following the local-prediction approach of
/// Ferrara, Bianchi, De Rosa & Piva (2012) in simplified form. Each channel
/// is predicted at every pixel from its four horizontal and vertical
/// neighbors (`predictionErrors`). Prediction error energy is then measured
/// separately for each of the four 2x2 lattice phases (`phaseEnergies`). In
/// demosaiced camera output, the recorded phases of a channel have clearly
/// higher prediction error than the interpolated ones. That period-2
/// imbalance is the CFA trace. `strength` turns it into one signed number:
/// the log ratio of recorded-phase to interpolated-phase energy. That's
/// clearly positive where the trace is present, near 0 where it's missing
/// (random pixels, rendered or resampled content), and negative where a
/// patch's Bayer grid is offset from the rest of the image's.
///
/// Popescu & Farid (2005) instead fit each channel's interpolation
/// coefficients with an EM algorithm and look for a periodic peak in the
/// spectrum of the resulting per-pixel probability map. That models any
/// linear demosaicing kernel exactly, not just a 4-neighbor average, and
/// gives a per-pixel probability rather than a per-block score, at the cost
/// of an iterative weighted least-squares fit per block and several tuning
/// parameters. A fixed predictor is cruder. It matches bilinear
/// demosaicing exactly and is only approximate for the edge-adaptive kernels
/// real cameras use, which shrinks the measured contrast. But the contrast
/// it does measure is deterministic, needs no linear algebra or new
/// dependency, and is directly comparable from block to block, which is
/// all a consistency check needs.
enum CFAPeriodicity {
    /// Energy floor, in squared gray levels, applied to each phase before
    /// taking a ratio. Interpolated sites often predict to within rounding,
    /// so their error can be exactly zero. The floor keeps the log ratio
    /// finite and stops it from rewarding perfectly flat areas.
    static let energyFloor = 0.01

    /// Fewest prediction-error samples a phase needs for its energy to be
    /// trusted.
    static let minimumSamplesPerPhase = 16

    /// Index of the 2x2 lattice phase of absolute pixel `(x, y)`:
    /// 0 = (even, even), 1 = (odd, even), 2 = (even, odd), 3 = (odd, odd).
    static func phase(x: Int, y: Int) -> Int {
        (y & 1) * 2 + (x & 1)
    }

    /// The two quincunx (checkerboard) halves of the lattice, as phase sets.
    /// A Bayer sensor records green on one of them.
    static let quincunxes: [Set<Int>] = [[0, 3], [1, 2]]

    /// Prediction error of every pixel of `tile` that has all four
    /// horizontal and vertical neighbors inside it:
    /// `e = v - (left + right + up + down) / 4`. The result is
    /// `(width - 2)` x `(height - 2)`, covering the tile minus its one-pixel
    /// border. Empty if the tile is smaller than 3x3.
    static func predictionErrors(of tile: PRNUPlane) -> PRNUPlane {
        guard tile.width >= 3, tile.height >= 3 else { return PRNUPlane(width: 0, height: 0) }
        let width = tile.width
        var errors = PRNUPlane(width: width - 2, height: tile.height - 2)
        for y in 1..<(tile.height - 1) {
            for x in 1..<(width - 1) {
                let i = y * width + x
                let neighbors = tile.values[i - 1] + tile.values[i + 1] + tile.values[i - width] + tile.values[i + width]
                errors[x - 1, y - 1] = tile.values[i] - 0.25 * neighbors
            }
        }
        return errors
    }

    /// Prediction error energy of each of the four lattice phases: the
    /// median squared error over that phase's samples. `origin` is the
    /// absolute image position of `errors`' top-left sample, so phases line
    /// up with the whole image's lattice wherever the block sits.
    ///
    /// The median, not the mean, keeps a few extreme errors from deciding a
    /// block's energy, such as a hard edge, or the border where a
    /// neighboring spliced block's random pixels bleed into the 4-neighbor
    /// predictor. A mean was tried first and let one bad neighbor flag an
    /// honest block.
    ///
    /// `nil` if any phase has fewer than `minimumSamplesPerPhase` samples.
    static func phaseEnergies(of errors: PRNUPlane, origin: (x: Int, y: Int)) -> [Double]? {
        var samples: [[Double]] = [[], [], [], []]
        for i in 0..<4 { samples[i].reserveCapacity(errors.values.count / 4 + 1) }
        for y in 0..<errors.height {
            for x in 0..<errors.width {
                let value = errors.values[y * errors.width + x]
                samples[phase(x: origin.x + x, y: origin.y + y)].append(value * value)
            }
        }
        guard samples.allSatisfy({ $0.count >= minimumSamplesPerPhase }) else { return nil }
        return samples.map { PRNUCorrelation.median($0) ?? 0 }
    }

    /// The CFA trace strength for one channel of one block, given which
    /// phases that channel was recorded at:
    /// `log(mean energy of recorded phases / mean energy of the others)`,
    /// each floored at `energyFloor`. Positive means the expected
    /// demosaicing pattern is present, about 0 means it's absent, and
    /// negative means the block's pattern sits on a different lattice. `0`
    /// if `recorded` is empty, covers every phase, or `energies` doesn't
    /// have four entries.
    static func strength(_ energies: [Double], recorded: Set<Int>) -> Double {
        guard energies.count == 4, !recorded.isEmpty, recorded.count < 4 else { return 0 }
        var recordedSum = 0.0
        var otherSum = 0.0
        for phase in 0..<4 {
            if recorded.contains(phase) {
                recordedSum += energies[phase]
            } else {
                otherSum += energies[phase]
            }
        }
        let recordedMean = max(energyFloor, recordedSum / Double(recorded.count))
        let otherMean = max(energyFloor, otherSum / Double(4 - recorded.count))
        return log(recordedMean / otherMean)
    }

    /// Each block's phase energies as fractions of that block's total, summed
    /// over `blocks`. Normalizing per block first means every block gets one
    /// equal vote on where the recorded phases are. Summing raw energies
    /// instead would let a single high-energy block (such as a patch of
    /// random pixels) outvote the rest of the image. Blocks with no energy
    /// at all are skipped.
    static func phaseVotes(_ blocks: [[Double]]) -> [Double] {
        var votes = [Double](repeating: 0, count: 4)
        for energies in blocks where energies.count == 4 {
            let total = energies.reduce(0, +)
            guard total > 0 else { continue }
            for phase in 0..<4 { votes[phase] += energies[phase] / total }
        }
        return votes
    }

    /// The quincunx (green) half with the higher share of `votes`.
    static func dominantQuincunx(_ votes: [Double]) -> Set<Int> {
        guard votes.count == 4 else { return quincunxes[0] }
        return votes[0] + votes[3] >= votes[1] + votes[2] ? quincunxes[0] : quincunxes[1]
    }

    /// The single phase (red or blue) with the highest share of `votes`.
    static func dominantPhase(_ votes: [Double]) -> Int {
        guard votes.count == 4 else { return 0 }
        var best = 0
        for phase in 1..<4 where votes[phase] > votes[best] { best = phase }
        return best
    }
}
