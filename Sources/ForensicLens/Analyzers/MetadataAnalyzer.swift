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

        let editingSoftwareMatch: (software: String, keyword: String)? = {
            guard let software = exif.software else { return nil }
            let lowered = software.lowercased()
            guard let match = config.metadata.suspiciousSoftwareKeywords.first(where: { lowered.contains($0.lowercased()) }) else { return nil }
            return (software, match)
        }()

        if let editingSoftwareMatch {
            indicators.append(Indicator(
                message: "Software tag reports \"\(editingSoftwareMatch.software)\", which matches known editing tool signature \"\(editingSoftwareMatch.keyword)\".",
                weight: 35
            ))
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

        // --- Cross-field checks -------------------------------------------
        //
        // Everything above flags one field in isolation: missing, malformed,
        // or out of range on its own. The checks below instead compare two
        // or more fields against each other. That distinction matters
        // forensically: a single missing or odd field is common in
        // unremarkable exports, but two fields that actively contradict
        // each other are much harder to explain away, because a genuine
        // capture-to-export pipeline writes related fields so that they
        // agree by construction. Each rule below produces its own named
        // `MetadataAnomaly` case rather than a shared, generic indicator,
        // so a report consumer (or a future scorer) can tell exactly which
        // inconsistency fired instead of pattern-matching indicator text.
        //
        // Every check below is skipped -- not treated as a failure -- when
        // one of the fields it compares is missing, since there is nothing
        // to cross-check in that case.

        if let gpsDateTime = exif.gpsDateTime, let original = exif.dateTimeOriginal {
            let drift = abs(gpsDateTime.timeIntervalSince(original))
            if drift > Double(config.metadata.maxGPSTimestampDriftSeconds) {
                indicators.append(MetadataAnomaly.gpsTimestampDrift(
                    driftSeconds: drift,
                    thresholdSeconds: config.metadata.maxGPSTimestampDriftSeconds,
                    gpsRaw: exif.rawGPSDateTime ?? "?",
                    originalRaw: exif.rawDateTimeOriginal ?? "?"
                ).indicator)
            }
        }

        if let digitized = exif.dateTimeDigitized, let original = exif.dateTimeOriginal {
            let drift = abs(digitized.timeIntervalSince(original))
            if drift > Double(config.metadata.maxDigitizedDriftSeconds) {
                indicators.append(MetadataAnomaly.digitizedDriftsFromOriginal(
                    driftSeconds: drift,
                    thresholdSeconds: config.metadata.maxDigitizedDriftSeconds,
                    digitizedRaw: exif.rawDateTimeDigitized ?? "?",
                    originalRaw: exif.rawDateTimeOriginal ?? "?"
                ).indicator)
            }
        }

        let hasCameraInfo = exif.make != nil || exif.model != nil
        if exif.hasGPSData != hasCameraInfo {
            indicators.append(MetadataAnomaly.partialMetadataStripping(
                gpsPresent: exif.hasGPSData,
                cameraInfoPresent: hasCameraInfo
            ).indicator)
        }

        if let altitude = exif.gpsAltitude, let altitudeRef = exif.gpsAltitudeRef, altitude < 0, altitudeRef != 1 {
            indicators.append(MetadataAnomaly.gpsAltitudeSignConflict(altitude: altitude, ref: altitudeRef).indicator)
        }

        if let editingSoftwareMatch,
           let make = exif.make, let model = exif.model,
           let modifyDate = exif.dateTime, let original = exif.dateTimeOriginal,
           modifyDate == original {
            indicators.append(MetadataAnomaly.editingSoftwareUneditedCameraClaim(
                software: editingSoftwareMatch.software,
                make: make,
                model: model,
                lens: exif.lensModel
            ).indicator)
        }

        let score = min(100, indicators.reduce(0) { $0 + $1.weight })
        let summary = indicators.isEmpty
            ? "EXIF metadata present and internally consistent; no anomalies found."
            : "\(indicators.count) metadata anomal\(indicators.count == 1 ? "y" : "ies") found."

        return AnalyzerFinding(analyzerID: identifier, score: score, summary: summary, indicators: indicators)
    }
}

/// A cross-field metadata inconsistency: two or more EXIF values that
/// contradict each other, as opposed to a single field being missing or
/// malformed on its own.
///
/// Each case owns the forensic reasoning for one specific comparison and
/// renders itself to an `Indicator` via `indicator`. Keeping these as named
/// cases (rather than building `Indicator`s ad hoc inline) means every
/// cross-field rule is independently testable and its rationale lives next
/// to its trigger condition instead of being scattered as string literals
/// through `analyze(_:config:)`.
enum MetadataAnomaly {
    /// `GPSTimeStamp`/`GPSDateStamp` and `DateTimeOriginal` disagree by more
    /// than `thresholdSeconds`.
    ///
    /// Per the EXIF spec, the GPS timestamp is always UTC. `DateTimeOriginal`
    /// carries no timezone field at all, and on most cameras reflects
    /// whatever the camera's clock was set to -- which is very often local
    /// time, not UTC. This check therefore assumes the two clocks are
    /// meant to read the same wall-clock time (i.e. the camera's clock is
    /// UTC, or happens to be set to the same offset GPS reports), and a
    /// small default threshold (5 minutes) is used to absorb ordinary GPS
    /// fix latency and clock drift, not timezone offsets. On a camera whose
    /// clock is genuinely set to local time in a non-zero UTC offset, this
    /// check will systematically flag every photo by roughly that offset --
    /// a known limitation. Deployments with local-time cameras should raise
    /// `maxGPSTimestampDriftSeconds` accordingly or disable this rule.
    case gpsTimestampDrift(driftSeconds: Double, thresholdSeconds: Int, gpsRaw: String, originalRaw: String)

    /// `DateTimeDigitized` disagrees with `DateTimeOriginal` by more than
    /// `thresholdSeconds`.
    ///
    /// For a straight-from-camera JPEG these two are normally identical or
    /// a second or two apart -- digitization happens at the moment of
    /// capture. A meaningful gap usually means the file was digitized
    /// (scanned, imported, or re-encoded) separately from when the image
    /// content was originally captured, which is exactly what happens when
    /// an editor re-saves a file and updates its own timestamp tags.
    case digitizedDriftsFromOriginal(driftSeconds: Double, thresholdSeconds: Int, digitizedRaw: String, originalRaw: String)

    /// GPS location data is present while camera Make/Model is absent, or
    /// vice versa.
    ///
    /// A real camera-captured photo either has both -- the camera writes
    /// its own identity alongside whatever location data it has -- or
    /// neither, if it has no GPS module or GPS was disabled. A file with
    /// one but not the other suggests an editing tool selectively stripped
    /// part of the original metadata rather than the whole block.
    ///
    /// The two directions aren't equally strong evidence: plenty of cameras
    /// never had a GPS module in the first place, so Make/Model-without-GPS
    /// is unremarkable on its own and weighted low. GPS-without-Make/Model
    /// is the more surprising combination -- GPS tags are typically written
    /// by the same device (usually a phone) that always identifies itself
    /// -- so it's weighted higher.
    case partialMetadataStripping(gpsPresent: Bool, cameraInfoPresent: Bool)

    /// `GPSAltitude` decodes as negative while `GPSAltitudeRef` does not say
    /// "below sea level" (`1`).
    ///
    /// `GPSAltitude` is spec'd as an unsigned RATIONAL: sign is supposed to
    /// come entirely from the separate `GPSAltitudeRef` byte, never from the
    /// numerator itself. A numerator that nonetheless decodes as negative
    /// under two's complement (see `ExifReader.readSignedRational`) is a
    /// value no conformant EXIF writer produces -- it's a strong sign the
    /// GPS block was hand-assembled or synthetically inserted rather than
    /// written by real camera/GPS firmware.
    case gpsAltitudeSignConflict(altitude: Double, ref: UInt8)

    /// The `Software` tag names a known editing tool, yet the file still
    /// carries a full camera-original identity (Make, Model, and
    /// optionally Lens) with `ModifyDate` exactly equal to
    /// `DateTimeOriginal` -- i.e. it claims to have never been re-saved.
    ///
    /// Running a file through Photoshop, GIMP, or similar and exporting it
    /// almost always updates the modification timestamp. A file that names
    /// an editor in `Software` but still claims, via an unchanged
    /// `ModifyDate`, to be an untouched camera original is asserting two
    /// things that don't normally co-occur -- on top of the `Software` tag
    /// being independently suspicious, this specific combination points at
    /// a more deliberate attempt to preserve an "unedited" appearance while
    /// software fingerprints leak through anyway.
    case editingSoftwareUneditedCameraClaim(software: String, make: String, model: String, lens: String?)

    /// Renders this anomaly to the `message` + `weight` pair the rest of
    /// `MetadataAnalyzer` deals in.
    var indicator: Indicator {
        switch self {
        case .gpsTimestampDrift(let driftSeconds, let thresholdSeconds, let gpsRaw, let originalRaw):
            let minutes = Int((driftSeconds / 60).rounded())
            return Indicator(
                message: "GPS timestamp (\(gpsRaw) UTC) and DateTimeOriginal (\(originalRaw)) differ by \(minutes) minute(s), beyond the configured \(thresholdSeconds / 60)-minute threshold.",
                weight: 25
            )
        case .digitizedDriftsFromOriginal(let driftSeconds, let thresholdSeconds, let digitizedRaw, let originalRaw):
            let minutes = Int((driftSeconds / 60).rounded())
            return Indicator(
                message: "DateTimeDigitized (\(digitizedRaw)) and DateTimeOriginal (\(originalRaw)) differ by \(minutes) minute(s), beyond the configured \(thresholdSeconds / 60)-minute threshold, suggesting the file was digitized separately from capture.",
                weight: 20
            )
        case .partialMetadataStripping(let gpsPresent, _):
            if gpsPresent {
                return Indicator(
                    message: "GPS location data is present but camera Make/Model is missing; camera-captured photos with GPS data typically also identify the capturing device.",
                    weight: 25
                )
            } else {
                return Indicator(
                    message: "Camera Make/Model is present but no GPS location data was recorded, an asymmetric combination that can indicate selective metadata stripping.",
                    weight: 10
                )
            }
        case .gpsAltitudeSignConflict(let altitude, let ref):
            return Indicator(
                message: "GPSAltitude (\(String(format: "%.2f", altitude))) is negative but GPSAltitudeRef (\(ref)) does not indicate \"below sea level\", a combination well-formed GPS metadata should never produce.",
                weight: 30
            )
        case .editingSoftwareUneditedCameraClaim(let software, let make, let model, let lens):
            let identity = [make, model, lens].compactMap { $0 }.joined(separator: " ")
            return Indicator(
                message: "Software tag reports \"\(software)\" (an editing tool) while the file still claims an unedited camera-original identity (\(identity)) with ModifyDate identical to DateTimeOriginal.",
                weight: 25
            )
        }
    }
}

/// The handful of EXIF fields `MetadataAnalyzer` cares about.
struct ExifSummary {
    var make: String?
    var model: String?
    var software: String?
    var lensModel: String?
    var dateTime: Date?
    var dateTimeOriginal: Date?
    var dateTimeDigitized: Date?
    var rawDateTime: String?
    var rawDateTimeOriginal: String?
    var rawDateTimeDigitized: String?

    /// Whether a GPS IFD was present at all, independent of whether any of
    /// its individual tags below parsed successfully. Used by the
    /// partial-stripping cross-field check, which cares about "is there a
    /// GPS block" rather than any specific GPS value.
    var hasGPSData = false

    /// `GPSDateStamp` + `GPSTimeStamp` combined into one `Date`. Per the
    /// EXIF spec these are always UTC, unlike `dateTimeOriginal` (see
    /// `MetadataAnomaly.gpsTimestampDrift`).
    var gpsDateTime: Date?
    var rawGPSDateTime: String?

    /// `GPSAltitude`, read as a *signed* rational even though the tag's
    /// declared type is the unsigned RATIONAL -- see `readSignedRational`.
    var gpsAltitude: Double?

    /// `GPSAltitudeRef`: `0` = above sea level, `1` = below. Any other raw
    /// byte value is non-conformant.
    var gpsAltitudeRef: UInt8?
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

        func readIFD(at offset: Int) -> (exifSubIFDOffset: UInt32?, gpsIFDOffset: UInt32?)? {
            let ifdOffset = tiffStart + offset
            guard let entryCount = u16(ifdOffset) else { return nil }
            var exifSubIFDOffset: UInt32?
            var gpsIFDOffset: UInt32?

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
                case 0x8825: // GPS IFD pointer
                    guard type == 4, let offsetValue = u32(valueFieldOffset) else { continue }
                    gpsIFDOffset = offsetValue
                default:
                    continue
                }
            }
            return (exifSubIFDOffset, gpsIFDOffset)
        }

        if let pointers = readIFD(at: Int(ifd0OffsetRaw)) {
            if let exifSubIFDOffset = pointers.exifSubIFDOffset {
                readSubIFD(data, tiffStart: tiffStart, offset: Int(exifSubIFDOffset), littleEndian: littleEndian, into: &summary)
            }
            if let gpsIFDOffset = pointers.gpsIFDOffset {
                readGPSIFD(data, tiffStart: tiffStart, offset: Int(gpsIFDOffset), littleEndian: littleEndian, into: &summary)
            }
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
            guard tag == 0x9003 || tag == 0x9004 || tag == 0xA434 else { continue } // DateTimeOriginal / DateTimeDigitized / LensModel
            guard type == 2 else { continue }
            let valueFieldOffset = entryOffset + 8
            let totalSize = byteSize(forType: type) * Int(count)
            guard let text = readASCII(data, tiffStart: tiffStart, valueFieldOffset: valueFieldOffset, totalSize: totalSize, littleEndian: littleEndian) else { continue }
            switch tag {
            case 0x9003:
                summary.rawDateTimeOriginal = text
                summary.dateTimeOriginal = parseExifDate(text)
            case 0x9004:
                summary.rawDateTimeDigitized = text
                summary.dateTimeDigitized = parseExifDate(text)
            case 0xA434:
                summary.lensModel = text
            default:
                break
            }
        }
    }

    /// Reads the GPS IFD (pointed to by IFD0 tag `0x8825`) for the tags the
    /// cross-field checks need: the GPS timestamp (`GPSTimeStamp` +
    /// `GPSDateStamp`, always UTC per the EXIF spec, unlike the camera's own
    /// `DateTimeOriginal`) and altitude (`GPSAltitude` + `GPSAltitudeRef`).
    private static func readGPSIFD(_ data: [UInt8], tiffStart: Int, offset: Int, littleEndian: Bool, into summary: inout ExifSummary) {
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
        summary.hasGPSData = true

        var hour: Double?
        var minute: Double?
        var second: Double?
        var dateStamp: String?

        for i in 0..<Int(entryCount) {
            let entryOffset = ifdOffset + 2 + i * 12
            guard entryOffset + 12 <= data.count,
                  let tag = u16(entryOffset),
                  let type = u16(entryOffset + 2),
                  let count = u32(entryOffset + 4)
            else { continue }
            let valueFieldOffset = entryOffset + 8

            switch tag {
            case 0x0005: // GPSAltitudeRef (BYTE) -- 0 = above sea level, 1 = below
                guard type == 1, valueFieldOffset < data.count else { continue }
                summary.gpsAltitudeRef = data[valueFieldOffset]
            case 0x0006: // GPSAltitude (RATIONAL, count 1) -- 8 bytes, always offset-stored
                guard count == 1, let relativeOffset = u32(valueFieldOffset) else { continue }
                summary.gpsAltitude = readSignedRational(data, offset: tiffStart + Int(relativeOffset), littleEndian: littleEndian)
            case 0x0007: // GPSTimeStamp: 3 RATIONALs (hour, minute, second) -- 24 bytes, always offset-stored
                guard count == 3, let relativeOffset = u32(valueFieldOffset) else { continue }
                let absoluteOffset = tiffStart + Int(relativeOffset)
                hour = readSignedRational(data, offset: absoluteOffset, littleEndian: littleEndian)
                minute = readSignedRational(data, offset: absoluteOffset + 8, littleEndian: littleEndian)
                second = readSignedRational(data, offset: absoluteOffset + 16, littleEndian: littleEndian)
            case 0x001D: // GPSDateStamp (ASCII "YYYY:MM:DD")
                guard type == 2 else { continue }
                let totalSize = byteSize(forType: type) * Int(count)
                dateStamp = readASCII(data, tiffStart: tiffStart, valueFieldOffset: valueFieldOffset, totalSize: totalSize, littleEndian: littleEndian)
            default:
                continue
            }
        }

        if let dateStamp, let hour, let minute, let second {
            // Built with plain interpolation rather than String(format:) and
            // "%@" -- the latter relies on NSObject bridging that isn't
            // reliably available under swift-corelibs-foundation on Linux.
            func twoDigits(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }
            let raw = "\(dateStamp) \(twoDigits(Int(hour.rounded()))):\(twoDigits(Int(minute.rounded()))):\(twoDigits(Int(second.rounded())))"
            summary.rawGPSDateTime = raw
            summary.gpsDateTime = parseExifDate(raw)
        }
    }

    /// Reads a TIFF RATIONAL as a *signed* `Double`, interpreting the
    /// numerator as two's-complement even though `GPSAltitude`'s declared
    /// type is the unsigned RATIONAL. Per spec, sign is meant to come from
    /// `GPSAltitudeRef`, not the numerator -- so a numerator that decodes
    /// as negative under two's complement is itself exactly the signal
    /// `MetadataAnomaly.gpsAltitudeSignConflict` is looking for: no
    /// conformant writer should ever produce one.
    private static func readSignedRational(_ data: [UInt8], offset: Int, littleEndian: Bool) -> Double? {
        guard offset + 8 <= data.count else { return nil }
        func rawU32(_ o: Int) -> UInt32? {
            guard o + 4 <= data.count else { return nil }
            let bytes = (0..<4).map { UInt32(data[o + $0]) }
            return littleEndian
                ? (bytes[3] << 24 | bytes[2] << 16 | bytes[1] << 8 | bytes[0])
                : (bytes[0] << 24 | bytes[1] << 16 | bytes[2] << 8 | bytes[3])
        }
        guard let numeratorRaw = rawU32(offset), let denominatorRaw = rawU32(offset + 4), denominatorRaw != 0 else { return nil }
        let numerator = Int32(bitPattern: numeratorRaw)
        return Double(numerator) / Double(denominatorRaw)
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
