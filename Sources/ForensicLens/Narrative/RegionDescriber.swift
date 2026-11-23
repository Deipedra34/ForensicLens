/// The analyzed image's pixel dimensions, so a narrative can say where in
/// the picture an area is ("in the upper right") instead of only giving
/// coordinates.
public struct ImageSize: Sendable, Equatable, Codable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

/// Describes flagged regions in plain words, keeping the exact pixel
/// coordinates in parentheses for anyone who wants to find them.
public enum RegionDescriber {
    /// "an area of 64x64 pixels in the upper right (x 128-192, y 64-128)",
    /// or without an image size, "an area of 64x64 pixels at x 128-192, y 64-128".
    public static func describe(_ region: Region, in size: ImageSize?) -> String {
        let extent = "an area of \(region.width)x\(region.height) pixels"
        let coordinates = "x \(region.x)-\(region.x + region.width), y \(region.y)-\(region.y + region.height)"
        guard let size, let place = position(of: region, in: size) else {
            return "\(extent) at \(coordinates)"
        }
        return "\(extent) \(place) (\(coordinates))"
    }

    /// Up to `limit` regions, described and joined into one phrase ("A, B,
    /// and C"), noting how many more there are beyond that.
    public static func list(_ regions: [Region], in size: ImageSize?, limit: Int = 3) -> String {
        let shown = regions.prefix(max(1, limit)).map { describe($0, in: size) }
        let remaining = regions.count - shown.count
        var parts = shown
        if remaining > 0 {
            parts.append("\(remaining) more \(remaining == 1 ? "area" : "areas")")
        }
        return joined(parts)
    }

    /// `regions` with overlapping or touching regions of a similar size
    /// (the larger at most `mergeSizeRatio` times the area of the smaller)
    /// merged into their bounding box, in order of first appearance.
    ///
    /// Block matching reports a copied patch as a run of overlapping 16px
    /// blocks, which reads far better as one area than as a list of
    /// cells. Regions of very different sizes are kept apart, so a small
    /// flagged block next to a large match isn't swallowed by it. Only
    /// what the narrative *says* is merged: overlays and the raw findings
    /// keep every region.
    public static func merged(_ regions: [Region]) -> [Region] {
        var parent = Array(regions.indices)

        func root(_ index: Int) -> Int {
            var current = index
            while parent[current] != current {
                parent[current] = parent[parent[current]]
                current = parent[current]
            }
            return current
        }

        for i in regions.indices {
            for j in regions.indices where j > i {
                guard touchesOrOverlaps(regions[i], regions[j]), similarInSize(regions[i], regions[j]) else { continue }
                let a = root(i)
                let b = root(j)
                if a != b {
                    parent[b] = a
                }
            }
        }

        var order: [Int] = []
        var members: [Int: [Region]] = [:]
        for index in regions.indices {
            let key = root(index)
            if members[key] == nil {
                order.append(key)
            }
            members[key, default: []].append(regions[index])
        }
        return order.compactMap { members[$0].flatMap(RegionClustering.bounding) }
    }

    /// Regions more than this many times larger (by area) than a neighbor
    /// aren't merged with it.
    static let mergeSizeRatio = 4

    static func touchesOrOverlaps(_ a: Region, _ b: Region) -> Bool {
        a.x <= b.x + b.width && b.x <= a.x + a.width && a.y <= b.y + b.height && b.y <= a.y + a.height
    }

    static func similarInSize(_ a: Region, _ b: Region) -> Bool {
        let areaA = RegionClustering.area(a)
        let areaB = RegionClustering.area(b)
        guard areaA > 0, areaB > 0 else { return false }
        return max(areaA, areaB) <= mergeSizeRatio * min(areaA, areaB)
    }

    /// "A", "A and B", "A, B, and C".
    public static func joined(_ parts: [String]) -> String {
        switch parts.count {
        case 0: return ""
        case 1: return parts[0]
        case 2: return "\(parts[0]) and \(parts[1])"
        default: return parts.dropLast().joined(separator: ", ") + ", and " + (parts.last ?? "")
        }
    }

    /// Where `region` sits in an image of `size`, by its center's third of
    /// the frame: "in the upper left", "on the right side", "in the
    /// center", or "covering most of the image". `nil` for a degenerate size.
    static func position(of region: Region, in size: ImageSize) -> String? {
        guard size.width > 0, size.height > 0 else { return nil }
        let imageArea = Double(size.width) * Double(size.height)
        let regionArea = Double(max(0, region.width)) * Double(max(0, region.height))
        if regionArea / imageArea >= 0.6 {
            return "covering most of the image"
        }

        let centerX = (Double(region.x) + Double(region.width) / 2) / Double(size.width)
        let centerY = (Double(region.y) + Double(region.height) / 2) / Double(size.height)
        let column = centerX < 1.0 / 3 ? "left" : (centerX < 2.0 / 3 ? "center" : "right")
        let row = centerY < 1.0 / 3 ? "upper" : (centerY < 2.0 / 3 ? "middle" : "lower")

        switch (row, column) {
        case ("middle", "center"):
            return "in the center"
        case ("middle", _):
            return "on the \(column) side"
        case ("upper", "center"):
            return "near the top"
        case ("lower", "center"):
            return "near the bottom"
        default:
            return "in the \(row) \(column)"
        }
    }
}
