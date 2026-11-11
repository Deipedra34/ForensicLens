/// Finds the `Exif` item of a HEIF file by walking its ISO base media file
/// format (ISO/IEC 14496-12) structure: the top-level `meta` box, its item
/// information (`iinf`/`infe`) to learn which item is the EXIF block, and
/// its item locations (`iloc`, plus `idat` for data stored inside `meta`) to
/// find that item's bytes.
///
/// Only what's needed for that is read; everything else is skipped. Any
/// size or offset that doesn't fit inside the file ends the search with
/// `nil` rather than a crash.
enum HEIFExifLocator {
    struct Box {
        let type: String
        /// Where the box's content starts (after its header) and ends.
        let start: Int
        let end: Int
    }

    struct Extent {
        let offset: Int
        let length: Int
    }

    struct ItemLocation {
        /// 0: offsets into the file; 1: offsets into the `idat` box.
        let constructionMethod: Int
        let extents: [Extent]
    }

    /// The raw bytes of the first `Exif` item, or `nil`.
    static func exifPayload(in data: [UInt8]) -> [UInt8]? {
        guard let meta = boxes(in: data, from: 0, to: data.count).first(where: { $0.type == "meta" }) else { return nil }
        // `meta` is a full box: 4 bytes of version and flags before its children.
        guard meta.start + 4 <= meta.end else { return nil }
        let children = boxes(in: data, from: meta.start + 4, to: meta.end)

        guard let iinf = children.first(where: { $0.type == "iinf" }),
              let iloc = children.first(where: { $0.type == "iloc" }),
              let exifID = exifItemIDs(in: data, iinf: iinf).first,
              let location = itemLocations(in: data, iloc: iloc)[exifID]
        else { return nil }

        let storage: (start: Int, end: Int)
        switch location.constructionMethod {
        case 0:
            storage = (0, data.count)
        case 1:
            guard let idat = children.first(where: { $0.type == "idat" }) else { return nil }
            storage = (idat.start, idat.end)
        default:
            return nil
        }

        var payload: [UInt8] = []
        for extent in location.extents {
            guard extent.offset >= 0, extent.offset <= storage.end - storage.start else { return nil }
            let start = storage.start + extent.offset
            // A zero length means "to the end of the storage".
            let length = extent.length == 0 ? storage.end - start : extent.length
            guard length >= 0, length <= storage.end - start,
                  payload.count + length <= ContainerMetadata.maximumExifSize
            else { return nil }
            payload += data[start..<(start + length)]
        }
        return payload.isEmpty ? nil : payload
    }

    /// The boxes laid out back to back in `data[from..<to]`. Stops at the
    /// first box whose size doesn't fit.
    static func boxes(in data: [UInt8], from: Int, to: Int) -> [Box] {
        var result: [Box] = []
        var position = from
        while position + 8 <= to {
            guard var reader = ByteReader(data, at: position, end: to),
                  let size32 = reader.u32(),
                  let type = reader.fourCC()
            else { break }
            var size = Int(size32)
            var headerSize = 8
            if size32 == 1 {
                guard let large = reader.u64(), large <= UInt64(to - position) else { break }
                size = Int(large)
                headerSize = 16
            } else if size32 == 0 {
                size = to - position
            }
            guard size >= headerSize, size <= to - position else { break }
            result.append(Box(type: type, start: position + headerSize, end: position + size))
            position += size
        }
        return result
    }

    /// IDs of items whose `infe` entry says `item_type` is `Exif`.
    static func exifItemIDs(in data: [UInt8], iinf: Box) -> [Int] {
        guard var reader = ByteReader(data, at: iinf.start, end: iinf.end),
              let version = reader.u8(), reader.skip(3),
              (version == 0 ? reader.u16().map(Int.init) : reader.u32().map(Int.init)) != nil
        else { return [] }

        var ids: [Int] = []
        for entry in boxes(in: data, from: reader.position, to: iinf.end) where entry.type == "infe" {
            guard var infe = ByteReader(data, at: entry.start, end: entry.end),
                  let infeVersion = infe.u8(), infeVersion >= 2, infe.skip(3)
            else { continue }
            let itemID = infeVersion == 2 ? infe.u16().map(Int.init) : infe.u32().map(Int.init)
            guard let itemID, infe.skip(2), let itemType = infe.fourCC() else { continue }
            if itemType == "Exif" {
                ids.append(itemID)
            }
        }
        return ids
    }

    /// Every item's location, keyed by item ID.
    static func itemLocations(in data: [UInt8], iloc: Box) -> [Int: ItemLocation] {
        guard var reader = ByteReader(data, at: iloc.start, end: iloc.end),
              let version = reader.u8(), version <= 2, reader.skip(3),
              let sizes = reader.u8(), let moreSizes = reader.u8()
        else { return [:] }
        let offsetSize = Int(sizes >> 4)
        let lengthSize = Int(sizes & 0x0F)
        let baseOffsetSize = Int(moreSizes >> 4)
        let indexSize = version >= 1 ? Int(moreSizes & 0x0F) : 0
        guard [offsetSize, lengthSize, baseOffsetSize, indexSize].allSatisfy({ [0, 4, 8].contains($0) }),
              let itemCount = version < 2 ? reader.u16().map(Int.init) : reader.u32().map(Int.init)
        else { return [:] }

        var locations: [Int: ItemLocation] = [:]
        for _ in 0..<itemCount {
            guard let itemID = version < 2 ? reader.u16().map(Int.init) : reader.u32().map(Int.init) else { break }
            var constructionMethod = 0
            if version >= 1 {
                guard let field = reader.u16() else { break }
                constructionMethod = Int(field & 0x0F)
            }
            guard reader.skip(2), // data_reference_index
                  let baseOffset = reader.unsigned(byteCount: baseOffsetSize),
                  let extentCount = reader.u16()
            else { break }

            var extents: [Extent] = []
            for _ in 0..<extentCount {
                guard reader.skip(indexSize),
                      let offset = reader.unsigned(byteCount: offsetSize),
                      let length = reader.unsigned(byteCount: lengthSize)
                else { return locations }
                let (start, overflow) = baseOffset.addingReportingOverflow(offset)
                guard !overflow, start <= UInt64(Int.max), length <= UInt64(Int.max) else { return locations }
                extents.append(Extent(offset: Int(start), length: Int(length)))
            }
            locations[itemID] = ItemLocation(constructionMethod: constructionMethod, extents: extents)
        }
        return locations
    }
}

/// Bounds-checked big-endian reads over `data[position..<end]`. Every read
/// returns `nil` (and reads nothing) if it would run past `end`.
struct ByteReader {
    private let data: [UInt8]
    private let end: Int
    private(set) var position: Int

    init?(_ data: [UInt8], at position: Int, end: Int) {
        guard position >= 0, position <= end, end <= data.count else { return nil }
        self.data = data
        self.position = position
        self.end = end
    }

    mutating func skip(_ count: Int) -> Bool {
        guard count >= 0, count <= end - position else { return false }
        position += count
        return true
    }

    mutating func unsigned(byteCount: Int) -> UInt64? {
        guard byteCount >= 0, byteCount <= 8, byteCount <= end - position else { return nil }
        var value: UInt64 = 0
        for index in 0..<byteCount {
            value = value << 8 | UInt64(data[position + index])
        }
        position += byteCount
        return value
    }

    mutating func u8() -> UInt8? { unsigned(byteCount: 1).map { UInt8($0) } }
    mutating func u16() -> UInt16? { unsigned(byteCount: 2).map { UInt16($0) } }
    mutating func u32() -> UInt32? { unsigned(byteCount: 4).map { UInt32($0) } }
    mutating func u64() -> UInt64? { unsigned(byteCount: 8) }

    mutating func fourCC() -> String? {
        guard 4 <= end - position else { return nil }
        let text = String(decoding: data[position..<(position + 4)], as: UTF8.self)
        position += 4
        return text
    }
}
