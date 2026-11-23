/// A region one flagged detector pointed at.
struct RegionClaim: Equatable {
    let analyzerID: String
    let family: EvidenceFamily
    let region: Region
}

/// Regions from different detectors that overlap, gathered into one area.
struct RegionCluster: Equatable {
    let claims: [RegionClaim]

    /// The detectors with a region in this area, sorted.
    var analyzerIDs: [String] {
        Array(Set(claims.map(\.analyzerID))).sorted()
    }

    /// The distinct evidence families behind those detectors.
    var families: Set<EvidenceFamily> {
        Set(claims.map(\.family))
    }

    /// The smallest rectangle containing every region in the area.
    var boundingRegion: Region {
        RegionClustering.bounding(claims.map(\.region)) ?? Region(x: 0, y: 0, width: 0, height: 0)
    }

    /// Where the detectors actually agree: the smallest rectangle
    /// containing every overlap between regions from two different
    /// detectors. Narrower than `boundingRegion` when one detector's region
    /// is much larger than the rest -- a large copy-move match that happens
    /// to cover a small spliced block shouldn't stretch the agreeing area
    /// to its own size. Falls back to `boundingRegion` for an area only one
    /// detector flagged.
    var agreementRegion: Region {
        var overlaps: [Region] = []
        for i in claims.indices {
            for j in claims.indices where j > i && claims[i].analyzerID != claims[j].analyzerID {
                guard RegionClustering.overlaps(claims[i].region, claims[j].region),
                      let overlap = claims[i].region.intersection(claims[j].region) else { continue }
                overlaps.append(overlap)
            }
        }
        return RegionClustering.bounding(overlaps) ?? boundingRegion
    }
}

/// Finds areas that more than one detector flagged.
///
/// Every region on a flagged, localizing detector's indicators (see
/// `DetectorProfile.localizes`) is a claim. Two claims from different
/// detectors belong to the same area when their overlap covers at least
/// `minimumOverlapFraction` of the smaller region: a 64px PRNU block and
/// a 16px ELA cell inside it overlap fully, while two blocks that merely
/// touch don't overlap at all. Areas are the connected groups of that
/// relation, so a chain of overlapping regions forms one area.
enum RegionClustering {
    /// Share of the smaller region that must be covered for two regions to
    /// count as the same area.
    static let minimumOverlapFraction = 0.25

    /// Cap on the regions taken from any one detector, so a finding with
    /// hundreds of flagged cells can't make the pairwise comparison slow.
    static let maximumRegionsPerDetector = 256

    static func area(_ region: Region) -> Int {
        max(0, region.width) * max(0, region.height)
    }

    /// The smallest rectangle containing all of `regions`, or `nil` for none.
    static func bounding(_ regions: [Region]) -> Region? {
        guard let minX = regions.map(\.x).min(),
              let minY = regions.map(\.y).min(),
              let maxX = regions.map({ $0.x + $0.width }).max(),
              let maxY = regions.map({ $0.y + $0.height }).max()
        else { return nil }
        return Region(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Whether `a` and `b` overlap enough to count as one area.
    static func overlaps(_ a: Region, _ b: Region) -> Bool {
        guard let overlap = a.intersection(b) else { return false }
        let smaller = min(area(a), area(b))
        guard smaller > 0 else { return false }
        return Double(area(overlap)) >= minimumOverlapFraction * Double(smaller)
    }

    /// The claims made by the flagged, localizing detectors among `findings`.
    static func claims(from findings: [AnalyzerFinding]) -> [RegionClaim] {
        var claims: [RegionClaim] = []
        for finding in findings where DetectorStatus.classify(finding) == .flagged {
            let profile = DetectorProfile.profile(for: finding.analyzerID)
            guard profile.localizes else { continue }
            var seen = Set<Region>()
            for region in finding.indicators.flatMap(\.regions) {
                guard seen.count < maximumRegionsPerDetector else { break }
                guard area(region) > 0, seen.insert(region).inserted else { continue }
                claims.append(RegionClaim(analyzerID: finding.analyzerID, family: profile.family, region: region))
            }
        }
        return claims
    }

    /// `claims` grouped into areas (connected groups of overlapping regions
    /// from different detectors), in the order each area's first claim
    /// appears. A claim that overlaps nothing is an area of its own.
    static func clusters(of claims: [RegionClaim]) -> [RegionCluster] {
        var parent = Array(claims.indices)

        func root(_ index: Int) -> Int {
            var current = index
            while parent[current] != current {
                parent[current] = parent[parent[current]]
                current = parent[current]
            }
            return current
        }

        for i in claims.indices {
            for j in claims.indices where j > i {
                guard claims[i].analyzerID != claims[j].analyzerID,
                      overlaps(claims[i].region, claims[j].region) else { continue }
                let a = root(i)
                let b = root(j)
                if a != b {
                    parent[b] = a
                }
            }
        }

        var order: [Int] = []
        var members: [Int: [RegionClaim]] = [:]
        for index in claims.indices {
            let key = root(index)
            if members[key] == nil {
                order.append(key)
            }
            members[key, default: []].append(claims[index])
        }
        return order.compactMap { members[$0].map(RegionCluster.init(claims:)) }
    }
}
