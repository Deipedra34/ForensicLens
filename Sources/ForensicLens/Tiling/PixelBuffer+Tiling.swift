import ImageDecoding

/// Errors raised while extracting or stitching tiles.
enum TilingError: Error, Equatable, CustomStringConvertible {
    /// `rect` falls outside the buffer it was extracted from, or has a
    /// non-positive width/height. `TilePlan.build` should never produce a
    /// rect like this, but extraction still checks rather than trusting
    /// that invariant blindly.
    case invalidRect(PixelRect)

    var description: String {
        switch self {
        case .invalidRect(let rect):
            return "Tile rect (\(rect.x),\(rect.y)) \(rect.width)x\(rect.height) is out of bounds or empty."
        }
    }
}

extension PixelBuffer {
    /// Returns a new, smaller buffer containing only the pixels inside
    /// `rect`, a rectangle expressed in this buffer's own coordinate space.
    ///
    /// This is the memory boundary between "the whole decoded image" and
    /// "one tile's pixels": from the moment this returns, a tiled analysis
    /// pass only ever holds a buffer sized to `rect`, not the full source
    /// image, which is what keeps a tile's peak extra memory proportional
    /// to one tile rather than to the whole image -- the point of tiling in
    /// the first place. Processing tiles one at a time (rather than
    /// extracting every tile up front into one array) is what actually
    /// realizes that bound; see `TilingCoordinator` and `SpatialTileMerger`,
    /// which both extract and discard one tile buffer per loop iteration.
    ///
    /// - Throws: `TilingError.invalidRect` if `rect` isn't fully contained
    ///   within this buffer.
    func extracting(_ rect: PixelRect) throws -> PixelBuffer {
        guard rect.width > 0, rect.height > 0,
              rect.x >= 0, rect.y >= 0,
              rect.x + rect.width <= width,
              rect.y + rect.height <= height
        else {
            throw TilingError.invalidRect(rect)
        }

        let rowByteCount = rect.width * channels
        var extracted = [UInt8](repeating: 0, count: rect.width * rect.height * channels)
        for row in 0..<rect.height {
            let srcRowStart = offset(x: rect.x, y: rect.y + row)
            let dstRowStart = row * rowByteCount
            extracted.replaceSubrange(dstRowStart..<(dstRowStart + rowByteCount), with: pixels[srcRowStart..<(srcRowStart + rowByteCount)])
        }

        return try PixelBuffer(width: rect.width, height: rect.height, channels: channels, pixels: extracted)
    }
}
