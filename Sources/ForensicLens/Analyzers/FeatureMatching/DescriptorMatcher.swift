/// An undirected pair of keypoints (indices into the keypoint array) whose
/// descriptors matched. `first < second` always.
struct KeypointMatch: Sendable, Equatable {
    let first: Int
    let second: Int
    let distance: Int
}

/// Matches an image's keypoints against *each other* to find candidate
/// copy-move correspondences.
///
/// Ordinary feature matching pairs keypoints across two different images.
/// Copy-move detection has only one, so every keypoint is compared against
/// every other keypoint in the same image -- excluding ones too close to it
/// spatially, which would otherwise "match" trivially (the same corner seen
/// at two adjacent pyramid levels, or its immediate neighbor).
///
/// Each keypoint keeps its nearest neighbor only if it passes Lowe's ratio
/// test: the best Hamming distance must be clearly smaller than the second
/// best. That rejects keypoints on repetitive or featureless texture, whose
/// best match is barely better than many others. The second-best candidate
/// is taken from outside a small radius around the best one, since the same
/// copied corner is often detected on two neighboring pyramid levels at
/// nearly the same position, and comparing a true match against its own
/// duplicate would wrongly fail the test.
///
/// All-pairs comparison is O(n^2) in keypoint count, but each comparison is
/// four XOR-popcounts, so even the default cap of 2000 keypoints costs a
/// few million cheap operations.
enum DescriptorMatcher {
    /// Matches at a Hamming distance above this (out of 256 bits) are
    /// rejected outright. Unrelated descriptors average about 128.
    static let maximumHammingDistance = 64

    /// Lowe's ratio: best distance must be below this fraction of the
    /// second best.
    static let ratio = 0.8

    /// Candidates within this many pixels of the best match are treated as
    /// duplicates of it when picking the second best.
    static let duplicateRadius = 4.0

    static func selfMatches(_ keypoints: [Keypoint], minimumSpatialDistance: Double) -> [KeypointMatch] {
        let count = keypoints.count
        guard count >= 2 else { return [] }

        let minimumSquaredDistance = minimumSpatialDistance * minimumSpatialDistance
        let duplicateSquaredRadius = duplicateRadius * duplicateRadius
        var distances = [Int](repeating: -1, count: count)
        var seen = Set<Int>()
        var matches: [KeypointMatch] = []

        for i in 0..<count {
            let keypoint = keypoints[i]
            var best = Int.max
            var bestIndex = -1
            for j in 0..<count {
                guard j != i, keypoint.position.squaredDistance(to: keypoints[j].position) >= minimumSquaredDistance else {
                    distances[j] = -1
                    continue
                }
                let distance = keypoint.descriptor.hammingDistance(to: keypoints[j].descriptor)
                distances[j] = distance
                if distance < best {
                    best = distance
                    bestIndex = j
                }
            }
            guard bestIndex >= 0, best <= maximumHammingDistance else { continue }

            let bestPosition = keypoints[bestIndex].position
            var secondBest = BinaryDescriptor.bitCount
            for j in 0..<count where j != bestIndex && distances[j] >= 0 && distances[j] < secondBest {
                guard keypoints[j].position.squaredDistance(to: bestPosition) >= duplicateSquaredRadius else { continue }
                secondBest = distances[j]
            }
            guard Double(best) < ratio * Double(secondBest) else { continue }

            let first = min(i, bestIndex)
            let second = max(i, bestIndex)
            guard seen.insert(first * count + second).inserted else { continue }
            matches.append(KeypointMatch(first: first, second: second, distance: best))
        }
        return matches
    }
}
