import Foundation
import ImageDecoding

/// Detects manipulation evidence hiding in EXIF metadata rather than pixels.
///
/// A camera writes a fairly predictable set of EXIF tags: a make and model,
/// a capture timestamp, and usually nothing claiming to be photo-editing
/// software. Once an image has been through an editor, three things tend
/// to change. A `Software` tag naming the editor shows up. The
/// last-modified timestamp drifts away from the original capture time,
/// sometimes by years. Or fields a camera would always fill in go missing
/// because whatever export path produced the file never wrote them in the
/// first place. None of this proves manipulation by itself — plenty of
/// people crop and export their own photos with nothing to hide — which is
/// why every observation here is treated as one weighted indicator, not a
/// verdict.
///
/// One thing worth calling out: this reads `rawBytes`, not `pixels`. EXIF
/// lives in a JPEG's `APP1` marker segment, which sits in the file header
/// before the compressed image scan even starts, so reading it doesn't
/// require decoding a single pixel. That's what lets this analyzer work
/// fine even on JPEGs whose pixel data ForensicLens can't decode (see
/// `ImageData`'s doc comment for more on that split).
public struct MetadataAnalyzer: Analyzer {
    public let identifier = "metadata"
    public let displayName = "EXIF / Metadata Analysis"

    public init() {}

    public func analyze(_ image: ImageData, config: ForensicLensConfig) throws -> AnalyzerFinding {
        guard image.format == .jpeg else {
            return AnalyzerFinding.clean(
                analyzerID: identifier,
                summary: "\(image.format?.rawValue.uppercased() ?? "This") format does not carry EXIF metadata; nothing to analyze."
            )
        }

        guard let exif = ExifReader.read(from: image.rawBytes) else {
            if config.metadata.flagMissingExif {
                return AnalyzerFinding(
                    analyzerID: identifier,
                    score: 20,
                    summary: "No EXIF metadata found in a JPEG file.",
                    indicators: [Indicator(message: "No Exif APP1 segment was found. Camera photos almost always carry one; its absence can indicate the metadata was stripped during editing.", weight: 20)]
                )
            }
            return AnalyzerFinding.clean(analyzerID: identifier, summary: "No EXIF metadata found in this JPEG.")
        }

        var indicators: [Indicator] = []

        if let software = exif.software {
            let lowered = software.lowercased()
            if let match = config.metadata.suspiciousSoftwareKeywords.first(where: { lowered.contains($0.lowercased()) }) {
                indicators.append(Indicator(
                    message: "Software tag reports \"\(software)\", which matches known editing tool signature \"\(match)\".",
                    weight: 35
                ))
            }
        }

        if exif.make == nil, exif.model == nil {
            indicators.append(Indicator(
                message: "No camera Make/Model recorded; this image may be a screenshot, scan, or software-generated export rather than a direct camera capture.",
                weight: 10
            ))
        }

        if let original = exif.dateTimeOriginal {
            if let modified = exif.dateTime {
                let drift = modified.timeIntervalSince(original)
                if drift < 0 {
                    indicators.append(Indicator(
                        message: "Last-modified timestamp (\(exif.rawDateTime ?? "?")) is earlier than the original capture timestamp (\(exif.rawDateTimeOriginal ?? "?")), which is not possible for an untouched file.",
                        weight: 50
                    ))
                } else if drift > Double(config.metadata.maxTimestampDriftSeconds) {
                    let days = Int(drift / 86400)
                    indicators.append(Indicator(
                        message: "File was last modified \(days) day(s) after the original capture timestamp (\(exif.rawDateTimeOriginal ?? "?") -> \(exif.rawDateTime ?? "?")), beyond the configured \(config.metadata.maxTimestampDriftSeconds / 86400)-day threshold for an ordinary re-save.",
                        weight: 30
                    ))
                }
            }
        } else if exif.dateTime != nil || exif.dateTimeDigitized != nil {
            indicators.append(Indicator(
                message: "No original capture timestamp (DateTimeOriginal) recorded, despite other EXIF timestamps being present.",
                weight: 8
            ))
        }

        let score = min(100, indicators.reduce(0) { $0 + $1.weight })
        let summary = indicators.isEmpty
            ? "EXIF metadata present and internally consistent; no anomalies found."
            : "\(indicators.count) metadata anomal\(indicators.count == 1 ? "y" : "ies") found."

        return AnalyzerFinding(analyzerID: identifier, score: score, summary: summary, indicators: indicators)
    }
}

/// The handful of EXIF fields `MetadataAnalyzer` cares about.
struct ExifSummary {
    var make: String?
    var model: String?
    var software: String?
    var dateTime: Date?
    var dateTimeOriginal: Date?
    var dateTimeDigitized: Date?
    var rawDateTime: String?
    var rawDateTimeOriginal: String?
}

/// A minimal TIFF/EXIF reader.
///
/// This reads just enough of the TIFF structure embedded in a JPEG's APP1
/// segment to pull out a handful of well-known tags: Make, Model, Software,
/// and the three EXIF timestamps. It's not a general-purpose EXIF library.
/// It doesn't walk every IFD, doesn't handle every TIFF data type, and
/// gives up cleanly (returns `nil`) on anything it doesn't recognize
/// instead of guessing. That scope matches what this tool actually needs —
/// it only ever asks "what do these five fields say," never "dump every
/// tag in the file."
enum ExifReader {
    private static let exifPreamble: [UInt8] = Array("Exif\0\0".utf8)

    /// Locates the APP1/Exif segment in a JPEG's byte stream, parses its
    /// TIFF structure, and extracts the tags `ExifSummary` cares about.
    /// Returns `nil` if no Exif segment is present or it's malformed.
    static func read(from data: [UInt8]) -> ExifSummary? {
        guard let tiffStart = locateTIFFHeader(in: data) else { return nil }
        return parseTIFF(data, tiffStart: tiffStart)
    }

    /// Walks JPEG marker segments looking for `APP1` containing an
    /// `"Exif\0\0"` preamble, and returns the byte offset where the TIFF
    /// header (the `"II"`/`"MM"` byte-order mark) begins.
    private static func locateTIFFHeader(in data: [UInt8]) -> Int? {
        guard data.count >= 4, data[0] == 0xFF, data[1] == 0xD8 else { return nil }
        var pos = 2
        while pos + 4 <= data.count {
            guard data[pos] == 0xFF else { return nil }
            let marker = data[pos + 1]
            // SOS begins entropy-coded scan data; there's nothing more to
            // find in the header from here on.
            if marker == 0xDA || marker == 0xD9 { return nil }
            // Markers with no payload (fill bytes, restart markers).
            if marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7) {
                pos += 2
                continue
            }
            guard pos + 4 <= data.count else { return nil }
            let length = Int(data[pos + 2]) << 8 | Int(data[pos + 3])
            guard length >= 2, pos + 2 + length <= data.count else { return nil }

            if marker == 0xE1 {
                let payloadStart = pos + 4
                let payloadEnd = pos + 2 + length
                if payloadEnd - payloadStart >= exifPreamble.count,
                   Array(data[payloadStart..<(payloadStart + exifPreamble.count)]) == exifPreamble {
                    return payloadStart + exifPreamble.count
                }
            }
            pos += 2 + length
        }
        return nil
    }

    private static func parseTIFF(_ data: [UInt8], tiffStart: Int) -> ExifSummary? {
        guard tiffStart + 8 <= data.count else { return nil }
        let littleEndian: Bool
        if data[tiffStart] == 0x49, data[tiffStart + 1] == 0x49 {
            littleEndian = true
        } else if data[tiffStart] == 0x4D, data[tiffStart + 1] == 0x4D {
            littleEndian = false
        } else {
            return nil
        }

        func u16(_ offset: Int) -> UInt16? {
            guard offset + 2 <= data.count else { return nil }
            let a = UInt16(data[offset]), b = UInt16(data[offset + 1])
            return littleEndian ? (b << 8 | a) : (a << 8 | b)
        }
        func u32(_ offset: Int) -> UInt32? {
            guard offset + 4 <= data.count else { return nil }
            let bytes = (0..<4).map { UInt32(data[offset + $0]) }
            return littleEndian
                ? (bytes[3] << 24 | bytes[2] << 16 | bytes[1] << 8 | bytes[0])
                : (bytes[0] << 24 | bytes[1] << 16 | bytes[2] << 8 | bytes[3])
        }

        guard let magic = u16(tiffStart + 2), magic == 0x002A else { return nil }
        guard let ifd0OffsetRaw = u32(tiffStart + 4) else { return nil }

        var summary = ExifSummary()

        func readIFD(at offset: Int) -> UInt32? {
            let ifdOffset = tiffStart + offset
            guard let entryCount = u16(ifdOffset) else { return nil }
            var exifSubIFDOffset: UInt32?

            for i in 0..<Int(entryCount) {
                let entryOffset = ifdOffset + 2 + i * 12
                guard entryOffset + 12 <= data.count,
                      let tag = u16(entryOffset),
                      let type = u16(entryOffset + 2),
                      let count = u32(entryOffset + 4)
                else { continue }

                let valueFieldOffset = entryOffset + 8
                let typeSize = Self.byteSize(forType: type)
                let totalSize = typeSize * Int(count)

                switch tag {
                case 0x010F, 0x0110, 0x0131, 0x0132: // Make, Model, Software, DateTime
                    guard type == 2 else { continue } // ASCII only
                    guard let text = readASCII(data, tiffStart: tiffStart, valueFieldOffset: valueFieldOffset, totalSize: totalSize, littleEndian: littleEndian) else { continue }
                    switch tag {
                    case 0x010F: summary.make = text
                    case 0x0110: summary.model = text
                    case 0x0131: summary.software = text
                    case 0x0132:
                        summary.rawDateTime = text
                        summary.dateTime = Self.parseExifDate(text)
                    default: break
                    }
                case 0x8769: // Exif SubIFD pointer
                    guard type == 4, let offsetValue = u32(valueFieldOffset) else { continue }
                    exifSubIFDOffset = offsetValue
                default:
                    continue
                }
            }
            return exifSubIFDOffset
        }

        if let exifSubIFDOffset = readIFD(at: Int(ifd0OffsetRaw)) {
            readSubIFD(data, tiffStart: tiffStart, offset: Int(exifSubIFDOffset), littleEndian: littleEndian, into: &summary)
        }

        return summary
    }

    private static func readSubIFD(_ data: [UInt8], tiffStart: Int, offset: Int, littleEndian: Bool, into summary: inout ExifSummary) {
        func u16(_ offset: Int) -> UInt16? {
            guard offset + 2 <= data.count else { return nil }
            let a = UInt16(data[offset]), b = UInt16(data[offset + 1])
            return littleEndian ? (b << 8 | a) : (a << 8 | b)
        }
        func u32(_ offset: Int) -> UInt32? {
            guard offset + 4 <= data.count else { return nil }
            let bytes = (0..<4).map { UInt32(data[offset + $0]) }
            return littleEndian
                ? (bytes[3] << 24 | bytes[2] << 16 | bytes[1] << 8 | bytes[0])
                : (bytes[0] << 24 | bytes[1] << 16 | bytes[2] << 8 | bytes[3])
        }

        let ifdOffset = tiffStart + offset
        guard let entryCount = u16(ifdOffset) else { return }

        for i in 0..<Int(entryCount) {
            let entryOffset = ifdOffset + 2 + i * 12
            guard entryOffset + 12 <= data.count,
                  let tag = u16(entryOffset),
                  let type = u16(entryOffset + 2),
                  let count = u32(entryOffset + 4)
            else { continue }
            guard tag == 0x9003 || tag == 0x9004 else { continue } // DateTimeOriginal / DateTimeDigitized
            guard type == 2 else { continue }
            let valueFieldOffset = entryOffset + 8
            let totalSize = byteSize(forType: type) * Int(count)
            guard let text = readASCII(data, tiffStart: tiffStart, valueFieldOffset: valueFieldOffset, totalSize: totalSize, littleEndian: littleEndian) else { continue }
            if tag == 0x9003 {
                summary.rawDateTimeOriginal = text
                summary.dateTimeOriginal = parseExifDate(text)
            } else {
                summary.dateTimeDigitized = parseExifDate(text)
            }
        }
    }

    private static func byteSize(forType type: UInt16) -> Int {
        switch type {
        case 1, 2, 7: return 1 // BYTE, ASCII, UNDEFINED
        case 3: return 2       // SHORT
        case 4, 9: return 4    // LONG, SLONG
        case 5, 10: return 8   // RATIONAL, SRATIONAL
        default: return 1
        }
    }

    /// Reads an ASCII TIFF field, whose bytes live inline in the 4-byte
    /// value field if they fit, or at an offset elsewhere in the file
    /// otherwise -- per the TIFF6 spec.
    private static func readASCII(_ data: [UInt8], tiffStart: Int, valueFieldOffset: Int, totalSize: Int, littleEndian: Bool) -> String? {
        guard totalSize > 0 else { return nil }
        let bytes: [UInt8]
        if totalSize <= 4 {
            guard valueFieldOffset + totalSize <= data.count else { return nil }
            bytes = Array(data[valueFieldOffset..<(valueFieldOffset + totalSize)])
        } else {
            func u32(_ offset: Int) -> UInt32? {
                guard offset + 4 <= data.count else { return nil }
                let raw = (0..<4).map { UInt32(data[offset + $0]) }
                return littleEndian
                    ? (raw[3] << 24 | raw[2] << 16 | raw[1] << 8 | raw[0])
                    : (raw[0] << 24 | raw[1] << 16 | raw[2] << 8 | raw[3])
            }
            guard let relativeOffset = u32(valueFieldOffset) else { return nil }
            let absoluteOffset = tiffStart + Int(relativeOffset)
            guard absoluteOffset >= 0, absoluteOffset + totalSize <= data.count else { return nil }
            bytes = Array(data[absoluteOffset..<(absoluteOffset + totalSize)])
        }
        // ASCII fields are null-terminated; trim the terminator and any
        // trailing padding.
        let trimmed = bytes.prefix(while: { $0 != 0 })
        guard !trimmed.isEmpty else { return nil }
        return String(decoding: trimmed, as: UTF8.self)
    }

    /// Parses an EXIF-format timestamp (`"YYYY:MM:DD HH:MM:SS"`) as UTC.
    /// EXIF carries no timezone by itself, so treating every timestamp as
    /// the same fixed zone keeps comparisons between them meaningful even
    /// though it may not match the camera's local time.
    private static func parseExifDate(_ raw: String) -> Date? {
        let segments = raw.split(separator: " ")
        guard segments.count == 2 else { return nil }
        let dateParts = segments[0].split(separator: ":")
        let timeParts = segments[1].split(separator: ":")
        guard dateParts.count == 3, timeParts.count == 3,
              let year = Int(dateParts[0]), let month = Int(dateParts[1]), let day = Int(dateParts[2]),
              let hour = Int(timeParts[0]), let minute = Int(timeParts[1]), let second = Int(timeParts[2])
        else { return nil }

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second

        var calendar = Calendar(identifier: .gregorian)
        guard let utc = TimeZone(identifier: "UTC") else { return nil }
        calendar.timeZone = utc
        components.timeZone = utc
        return calendar.date(from: components)
    }
}
