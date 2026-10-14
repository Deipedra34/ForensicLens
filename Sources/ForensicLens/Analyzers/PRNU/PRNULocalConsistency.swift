/// One block of a `PRNUConsistencyMap`.
public struct PRNUBlockConsistency: Sendable, Equatable {
    public enum Status: String, Sendable, Equatable {
        /// The block's noise matches the rest of the image.
        case consistent
        /// The block's noise consistency fell below the threshold.
        case inconsistent
        /// The block wasn't judged: most of it is clipped to pure black or
        /// white, where a sensor records no noise at all, so a missing noise
        /// signature there means nothing.
        case unreliable
    }

    /// The block's area, in the original (full-resolution) image's pixel
    /// coordinates.
    public let region: Region

    public let status: Status

    /// `PRNUCorrelation.blockConsistency` for this block, 0...1. `nil` for
    /// an unreliable block.
    public let consistency: Double?

    /// This block's residual noise level divided by the image's aggregate
    /// level (excluding this block). `nil` for an unreliable block, or when
    /// the aggregate has no measurable noise.
    public let noiseLevelRatio: Double?
}

/// The per-block result of the local PRNU consistency check: a coarse heat
/// map of how well each block's sensor noise agrees with the rest of the
/// image, in row-major block order.
public struct PRNUConsistencyMap: Sendable, Equatable {
    public let columns: Int
    public let rows: Int
    public let blocks: [PRNUBlockConsistency]

    /// Median residual noise level of the reliable blocks, in working
    /// resolution gray levels.
    public let aggregateNoiseLevel: Double

    public var reliableBlocks: [PRNUBlockConsistency] {
        blocks.filter { $0.status != .unreliable }
    }

    public var inconsistentBlocks: [PRNUBlockConsistency] {
        blocks.filter { $0.status == .inconsistent }
    }
}

/// Walks a noise residual block by block and compares each block's noise
/// signature against the aggregate signature of every other block.
///
/// A PRNU pattern is unique per pixel, and that's what makes it a
/// fingerprint. So nothing else in a single image says what one block's
/// pattern *should* be, and pixel-wise correlation between a block and the
/// rest of the same image would measure nothing. What one sensor does
/// imprint uniformly across a frame is the character of its noise: how
/// strong it is, and how it correlates with itself across neighboring
/// pixels (shaped by the sensor, its color filter array, and the camera's
/// demosaicing). This check compares that character, block by block, with
/// `PRNUCorrelation.noiseSignature` and `blockConsistency`. A spliced region
/// from another source, or one that was smoothed, resampled, re-rendered
/// or synthesized, generally carries noise of a different strength or
/// structure. A region from a different camera with *statistically
/// identical* noise is beyond any single-image check; that's what
/// reference-fingerprint verification (`PRNUReferenceFingerprint`) is for.
enum PRNULocalConsistency {
    /// A block more than this fraction clipped (luma at or within 2 levels
    /// of 0 or 255) is marked unreliable rather than judged.
    static let maximumClippedFraction = 0.5

    /// Builds the consistency map for `residual` (with matching `luma`,
    /// both at working resolution) over non-overlapping
    /// `blockSize` x `blockSize` tiles. Partial blocks at the right and
    /// bottom edges are left out. `scale` maps working-resolution
    /// coordinates back to the original image for each block's `region`,
    /// clipped to `originalWidth` x `originalHeight`.
    static func map(
        residual: PRNUPlane,
        luma: PRNUPlane,
        blockSize: Int,
        threshold: Double,
        scale: Int,
        originalWidth: Int,
        originalHeight: Int
    ) -> PRNUConsistencyMap {
        let columns = blockSize > 0 ? residual.width / blockSize : 0
        let rows = blockSize > 0 ? residual.height / blockSize : 0
        guard columns > 0, rows > 0, luma.width == residual.width, luma.height == residual.height else {
            return PRNUConsistencyMap(columns: 0, rows: 0, blocks: [], aggregateNoiseLevel: 0)
        }

        struct Cell {
            let region: Region
            let reliable: Bool
            let signature: PRNUCorrelation.NoiseSignature
        }

        var cells: [Cell] = []
        cells.reserveCapacity(columns * rows)
        for row in 0..<rows {
            for column in 0..<columns {
                let x = column * blockSize
                let y = row * blockSize
                let original = Region(x: x * scale, y: y * scale, width: blockSize * scale, height: blockSize * scale)
                let region = original.intersection(Region(x: 0, y: 0, width: originalWidth, height: originalHeight)) ?? original
                cells.append(Cell(
                    region: region,
                    reliable: clippedFraction(luma, x: x, y: y, size: blockSize) <= maximumClippedFraction,
                    signature: PRNUCorrelation.noiseSignature(of: residual, x: x, y: y, size: blockSize)
                ))
            }
        }

        // Leave-one-out aggregates over the reliable blocks only: noise
        // level over all of them, and each lag coefficient over the ones
        // that have measurable noise (and therefore a defined coefficient).
        let reliableIndices = cells.indices.filter { cells[$0].reliable }
        let levels = reliableIndices.map { cells[$0].signature.standardDeviation }
        let aggregateLevels = PRNUCorrelation.leaveOneOutMedians(levels)

        let measuredIndices = reliableIndices.filter { cells[$0].signature.lagCorrelations != nil }
        var aggregateCorrelations: [Int: [Double]] = [:]
        if measuredIndices.count >= 2 {
            let lagCount = PRNUCorrelation.signatureLags.count
            var perBlock = [[Double]](repeating: [Double](repeating: 0, count: lagCount), count: measuredIndices.count)
            for lag in 0..<lagCount {
                let samples = measuredIndices.map { cells[$0].signature.lagCorrelations?[lag] ?? 0 }
                let medians = PRNUCorrelation.leaveOneOutMedians(samples)
                for j in 0..<medians.count { perBlock[j][lag] = medians[j] }
            }
            for (j, index) in measuredIndices.enumerated() {
                aggregateCorrelations[index] = perBlock[j]
            }
        }
        // A block with no measurable noise has no leave-one-out entry of
        // its own, so it's compared against the median over every measured
        // block. Its consistency comes out 0 regardless, since it has no
        // signature to compare.
        let fallbackCorrelations: [Double]? = measuredIndices.isEmpty ? nil : PRNUCorrelation.signatureLags.indices.map { lag in
            PRNUCorrelation.median(measuredIndices.map { cells[$0].signature.lagCorrelations?[lag] ?? 0 }) ?? 0
        }

        var aggregateLevelByIndex: [Int: Double] = [:]
        for (j, index) in reliableIndices.enumerated() { aggregateLevelByIndex[index] = aggregateLevels[j] }

        let blocks = cells.indices.map { index -> PRNUBlockConsistency in
            let cell = cells[index]
            guard cell.reliable, let aggregateLevel = aggregateLevelByIndex[index] else {
                return PRNUBlockConsistency(region: cell.region, status: .unreliable, consistency: nil, noiseLevelRatio: nil)
            }
            let consistency = PRNUCorrelation.blockConsistency(
                cell.signature,
                aggregateLagCorrelations: aggregateCorrelations[index] ?? fallbackCorrelations,
                aggregateStandardDeviation: aggregateLevel
            )
            return PRNUBlockConsistency(
                region: cell.region,
                status: consistency < threshold ? .inconsistent : .consistent,
                consistency: consistency,
                noiseLevelRatio: aggregateLevel > 0 ? cell.signature.standardDeviation / aggregateLevel : nil
            )
        }

        return PRNUConsistencyMap(
            columns: columns,
            rows: rows,
            blocks: blocks,
            aggregateNoiseLevel: PRNUCorrelation.median(levels) ?? 0
        )
    }

    /// Fraction of the block's luma samples at or within 2 gray levels of
    /// pure black or white.
    static func clippedFraction(_ luma: PRNUPlane, x: Int, y: Int, size: Int) -> Double {
        guard size > 0, x >= 0, y >= 0, x + size <= luma.width, y + size <= luma.height else { return 1 }
        var clipped = 0
        for row in 0..<size {
            let rowStart = (y + row) * luma.width + x
            for col in 0..<size {
                let value = luma.values[rowStart + col]
                if value <= 2 || value >= 253 { clipped += 1 }
            }
        }
        return Double(clipped) / Double(size * size)
    }
}
