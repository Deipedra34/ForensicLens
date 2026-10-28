import Foundation
import ForensicLens
import ImageDecoding

/// The JSON-in, JSON-out API behind the browser demo.
///
/// Everything here is plain Swift over the existing library: the bytes the
/// page hands over are decoded with `ImageData.load` and run through the
/// same `ForensicLensEngine` the CLI uses, with default config. Nothing is
/// reimplemented. The only WebAssembly-specific code is the thin export
/// layer in `Exports.swift`, which moves bytes across the JS boundary and
/// calls into this type.
///
/// Every entry point returns a JSON value, never a thrown error, because
/// nothing can catch a Swift error on the JavaScript side of the boundary.
/// Bad input (empty, corrupt, or unsupported bytes, an unknown analyzer)
/// comes back as `{"error": "..."}` for the page to show.
enum WebAnalysisAPI {
    /// One analyzer, as the page lists it.
    struct AnalyzerInfo: Codable, Equatable {
        let id: String
        let name: String
    }

    /// What was decoded from the bytes, so the page can scale overlays and
    /// explain why pixel analyzers didn't run (for example, JPEG pixels
    /// aren't decoded yet).
    struct ImageInfo: Codable, Equatable {
        let format: String?
        let width: Int?
        let height: Int?
        let channels: Int?
        let pixelsDecoded: Bool
    }

    /// The result of one call. Exactly one of `report` and `error` is set;
    /// `image` accompanies a report from `analyze`.
    struct Response: Codable {
        var report: ForensicReport?
        var image: ImageInfo?
        var error: String?
    }

    static let engine = ForensicLensEngine(config: .default)

    /// Display names, read from the analyzers themselves (the same way the
    /// HTML report does) so they can't drift from the library's.
    static let displayNames: [String: String] = {
        let analyzers: [any Analyzer] = [ELAAnalyzer(), MetadataAnalyzer(), CloneDetectionAnalyzer(), DoubleCompressionAnalyzer(), PRNUAnalyzer(), CFAAnalyzer(), JPEGGhostAnalyzer()]
        return Dictionary(uniqueKeysWithValues: analyzers.map { ($0.identifier, $0.displayName) })
    }()

    /// Every analyzer the engine runs, in run order.
    static func analyzers() -> [AnalyzerInfo] {
        engine.availableAnalyzerIDs.map { AnalyzerInfo(id: $0, name: displayNames[$0] ?? $0) }
    }

    /// Decodes `bytes` and runs `analyzerID` alone (or every analyzer if
    /// `nil`). Running one analyzer per call is what lets the page show
    /// progress, analyzer by analyzer, then combine the findings with
    /// `combine`.
    static func analyze(_ bytes: [UInt8], only analyzerID: String?) -> Response {
        guard !bytes.isEmpty else {
            return Response(error: "No image data was provided.")
        }
        if let analyzerID, !engine.availableAnalyzerIDs.contains(analyzerID) {
            return Response(error: "Unknown analyzer \"\(analyzerID)\".")
        }

        let image: ImageData
        do {
            image = try ImageData.load(bytes)
        } catch ImageDecodingError.badMagicNumber {
            return Response(error: "Unrecognized image format. Supported: BMP, PPM/PGM (all analyzers), and JPEG (metadata only; JPEG pixel decoding isn't implemented yet).")
        } catch {
            return Response(error: "Could not decode the image: \(error)")
        }

        let report = engine.run(on: image, only: analyzerID.map { [$0] })
        let info = ImageInfo(
            format: image.format?.rawValue,
            width: image.pixels?.width,
            height: image.pixels?.height,
            channels: image.pixels?.channels,
            pixelsDecoded: image.pixels != nil
        )
        return Response(report: report, image: info)
    }

    /// Combines the findings of separate `analyze` calls (a JSON array of
    /// `AnalyzerFinding`) into one report, exactly as a single full run
    /// would: `SuspicionScorer` is order-independent.
    static func combine(_ findingsJSON: [UInt8]) -> Response {
        do {
            let findings = try JSONDecoder().decode([AnalyzerFinding].self, from: Data(findingsJSON))
            return Response(report: SuspicionScorer().score(findings))
        } catch {
            return Response(error: "Could not read the findings to combine: \(error)")
        }
    }

    /// `value` as UTF-8 JSON. Falls back to a fixed error object (which
    /// can't fail to encode) rather than ever returning nothing.
    static func json<T: Encodable>(_ value: T) -> [UInt8] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(value) {
            return [UInt8](data)
        }
        return Array(#"{"error":"Could not encode the result as JSON."}"#.utf8)
    }
}
