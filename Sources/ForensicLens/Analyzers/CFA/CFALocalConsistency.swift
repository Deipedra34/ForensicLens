import ImageDecoding

/// One block of a `CFAConsistencyMap`.
public struct CFABlockConsistency: Sendable, Equatable {
    public enum Status: String, Sendable, Equatable {
        /// The block shows the same demosaicing pattern as the rest of the image.
        case consistent
        /// The block's pattern is missing, weak, or on a different lattice phase.
        case inconsistent
        /// The block wasn't judged: its green channel is mostly clipped, or
        /// too flat to reveal any interpolation pattern (a featureless,
        /// noiseless area looks the same whether demosaiced or not).
        case unreliable
    }

    /// The block's area, in image pixel coordinates.
    public let region: Region

    public let status: Status

    /// The block's CFA trace strength relative to the image's own typical
    /// strength: about 1 for a typical block, about 0 where the pattern is
    /// missing, negative where it sits on a different lattice phase. `nil`
    /// for an unreliable block.
    public let consistency: Double?

    /// Whether the block's green channel shows a clear demosaicing pattern
    /// on the *opposite* quincunx from the rest of the image. That's the
    /// signature of a patch whose Bayer grid is offset from the image's (or
    /// of some resampled content), not just a patch with no pattern at all.
    public let latticeShifted: Bool
}

/// The per-block result of CFA consistency analysis: a coarse heat map of
/// how well each block's demosaicing trace agrees with the rest of the
/// image, in row-major block order.
public struct CFAConsistencyMap: Sendable, Equatable {
    public let columns: Int
    public let rows: Int
    public let blocks: [CFABlockConsistency]

    /// Median green-channel trace strength (`CFAPeriodicity.strength`) over
    /// the reliable blocks: the image's own baseline. 0 if there are none.
    public let imageStrength: Double

    /// How many blocks had measurable, unclipped green detail, whether or
    /// not the image turned out to carry a trace to compare them against.
    public let measuredBlockCount: Int

    /// Whether the image as a whole shows a demosaicing trace strong enough
    /// to compare blocks against (`imageStrength` at least
    /// `CFALocalConsistency.minimumChannelStrength`). When it doesn't, no
    /// block is judged and every block is `unreliable`.
    public var tracePresent: Bool {
        imageStrength >= CFALocalConsistency.minimumChannelStrength
    }

    public var reliableBlocks: [CFABlockConsistency] {
        blocks.filter { $0.status != .unreliable }
    }

    public var inconsistentBlocks: [CFABlockConsistency] {
        blocks.filter { $0.status == .inconsistent }
    }
}

/// Walks an RGB image block by block, measures each channel's CFA trace
/// strength per block (`CFAPeriodicity`), and compares every block against
/// the image's own baseline.
///
/// The recorded lattice phase of each channel isn't assumed (cameras use
/// all four Bayer orderings, and a crop shifts the grid by however many
/// pixels were trimmed). It's voted on by every reliable block
/// (`CFAPeriodicity.phaseVotes`). Each channel's strengths are then
/// normalized by that channel's median, so a block's `consistency` reads as
/// "this fraction of the image's typical trace". The channels are combined
/// with green weighted double: green is sampled at twice the density of red
/// or blue, so its estimate is the steadiest. A channel whose median
/// strength is below `minimumChannelStrength` carries no usable trace in
/// this image and is left out. If that's green, the whole image is reported
/// as having no trace to compare against.
///
/// Works one block at a time, reading each channel's block (plus a
/// one-pixel border) straight from the `PixelBuffer`, so memory stays at a
/// few block-sized planes regardless of image size.
enum CFALocalConsistency {
    /// A channel more than this fraction clipped (at or within 2 levels of
    /// 0 or 255) within a block isn't used for that block: a clipped sensor
    /// site records no detail, so neither does its interpolation pattern.
    static let maximumClippedFraction = 0.5

    /// A channel's largest phase energy (median squared prediction error,
    /// in squared gray levels) must reach this for the block to reveal any
    /// pattern. Below it the block is effectively flat and noiseless.
    static let minimumMeasurableEnergy = 0.25

    /// Median strength (a log energy ratio, so 0.4 is about a 1.5x energy
    /// contrast) a channel needs across the image to count as carrying a
    /// demosaicing trace at all.
    static let minimumChannelStrength = 0.4

    /// Per-channel weights (red, green, blue) for combining strengths.
    static let channelWeights: [Double] = [1, 2, 1]

    /// A green strength below `-minimumChannelStrength` on the image's
    /// recorded quincunx counts as a pattern on the opposite lattice.
    static let shiftedStrength = -CFALocalConsistency.minimumChannelStrength

    /// Builds the consistency map for `buffer` over non-overlapping
    /// `blockSize` x `blockSize` blocks (`blockSize` must be even, so every
    /// block starts on the same lattice phase). Partial blocks at the right
    /// and bottom edges are left out. Images with fewer than three channels
    /// give an empty map.
    static func map(_ buffer: PixelBuffer, blockSize: Int, threshold: Double) -> CFAConsistencyMap {
        let columns = blockSize > 0 ? buffer.width / blockSize : 0
        let rows = blockSize > 0 ? buffer.height / blockSize : 0
        guard buffer.channels >= 3, columns > 0, rows > 0 else {
            return CFAConsistencyMap(columns: 0, rows: 0, blocks: [], imageStrength: 0, measuredBlockCount: 0)
        }

        struct Cell {
            let region: Region
            /// Per channel (R, G, B): phase energies, or `nil` if the
            /// channel isn't usable in this block.
            let energies: [[Double]?]
            var reliable: Bool { energies[1] != nil }
        }

        var cells: [Cell] = []
        cells.reserveCapacity(columns * rows)
        for row in 0..<rows {
            for column in 0..<columns {
                let region = Region(x: column * blockSize, y: row * blockSize, width: blockSize, height: blockSize)
                let energies = (0..<3).map { channel in usableEnergies(buffer, channel: channel, block: region) }
                cells.append(Cell(region: region, energies: energies))
            }
        }

        let reliable = cells.filter(\.reliable)

        // Per channel: where it was recorded (voted by every block where it's
        // usable), each block's strength on that lattice, and the image median.
        var strengths = [[Double?]](repeating: [Double?](repeating: nil, count: cells.count), count: 3)
        var medians = [Double](repeating: 0, count: 3)
        for channel in 0..<3 {
            let usable = reliable.compactMap { $0.energies[channel] }
            let votes = CFAPeriodicity.phaseVotes(usable)
            let recorded: Set<Int> = channel == 1
                ? CFAPeriodicity.dominantQuincunx(votes)
                : [CFAPeriodicity.dominantPhase(votes)]
            for index in cells.indices where cells[index].reliable {
                if let energies = cells[index].energies[channel] {
                    strengths[channel][index] = CFAPeriodicity.strength(energies, recorded: recorded)
                }
            }
            medians[channel] = PRNUCorrelation.median(strengths[channel].compactMap { $0 }) ?? 0
        }

        let imageStrength = medians[1]
        guard imageStrength >= minimumChannelStrength else {
            let blocks = cells.map { CFABlockConsistency(region: $0.region, status: .unreliable, consistency: nil, latticeShifted: false) }
            return CFAConsistencyMap(columns: columns, rows: rows, blocks: blocks, imageStrength: imageStrength, measuredBlockCount: reliable.count)
        }

        let presentChannels = (0..<3).filter { medians[$0] >= minimumChannelStrength }
        let blocks = cells.indices.map { index -> CFABlockConsistency in
            let cell = cells[index]
            guard cell.reliable else {
                return CFABlockConsistency(region: cell.region, status: .unreliable, consistency: nil, latticeShifted: false)
            }
            var weighted = 0.0
            var totalWeight = 0.0
            for channel in presentChannels {
                guard let strength = strengths[channel][index] else { continue }
                weighted += channelWeights[channel] * strength / medians[channel]
                totalWeight += channelWeights[channel]
            }
            let consistency = totalWeight > 0 ? weighted / totalWeight : 0
            return CFABlockConsistency(
                region: cell.region,
                status: consistency < threshold ? .inconsistent : .consistent,
                consistency: consistency,
                latticeShifted: (strengths[1][index] ?? 0) < shiftedStrength
            )
        }
        return CFAConsistencyMap(columns: columns, rows: rows, blocks: blocks, imageStrength: imageStrength, measuredBlockCount: reliable.count)
    }

    /// `channel`'s phase energies over `block`, or `nil` if the channel is
    /// mostly clipped there, too flat to measure, or the block is too small.
    static func usableEnergies(_ buffer: PixelBuffer, channel: Int, block: Region) -> [Double]? {
        guard clippedFraction(buffer, channel: channel, block: block) <= maximumClippedFraction else { return nil }

        // The block plus a one-pixel border (where the image has one), so
        // every block pixel not on the image's own edge gets all four
        // neighbors.
        let x0 = max(0, block.x - 1)
        let y0 = max(0, block.y - 1)
        let x1 = min(buffer.width, block.x + block.width + 1)
        let y1 = min(buffer.height, block.y + block.height + 1)
        let tile = channelPlane(buffer, channel: channel, region: Region(x: x0, y: y0, width: x1 - x0, height: y1 - y0))

        let errors = CFAPeriodicity.predictionErrors(of: tile)
        guard let energies = CFAPeriodicity.phaseEnergies(of: errors, origin: (x0 + 1, y0 + 1)),
              (energies.max() ?? 0) >= minimumMeasurableEnergy
        else { return nil }
        return energies
    }

    /// One channel of `region` (which must lie inside the buffer) as a plane.
    static func channelPlane(_ buffer: PixelBuffer, channel: Int, region: Region) -> PRNUPlane {
        guard region.width > 0, region.height > 0, channel >= 0, channel < buffer.channels,
              region.x >= 0, region.y >= 0,
              region.x + region.width <= buffer.width, region.y + region.height <= buffer.height
        else { return PRNUPlane(width: 0, height: 0) }

        var values = [Double](repeating: 0, count: region.width * region.height)
        for row in 0..<region.height {
            for col in 0..<region.width {
                values[row * region.width + col] = Double(buffer.pixels[buffer.offset(x: region.x + col, y: region.y + row) + channel])
            }
        }
        return PRNUPlane(width: region.width, height: region.height, values: values)
    }

    /// Fraction of `block`'s samples of `channel` at or within 2 gray
    /// levels of 0 or 255. A block outside the buffer counts as fully clipped.
    static func clippedFraction(_ buffer: PixelBuffer, channel: Int, block: Region) -> Double {
        guard block.width > 0, block.height > 0, channel >= 0, channel < buffer.channels,
              block.x >= 0, block.y >= 0,
              block.x + block.width <= buffer.width, block.y + block.height <= buffer.height
        else { return 1 }

        var clipped = 0
        for row in 0..<block.height {
            for col in 0..<block.width {
                let value = buffer.pixels[buffer.offset(x: block.x + col, y: block.y + row) + channel]
                if value <= 2 || value >= 253 { clipped += 1 }
            }
        }
        return Double(clipped) / Double(block.width * block.height)
    }
}
