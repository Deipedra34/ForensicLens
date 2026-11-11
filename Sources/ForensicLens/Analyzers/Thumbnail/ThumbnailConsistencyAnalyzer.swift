import Foundation
import ImageDecoding

/// Compares the thumbnail embedded in an image's EXIF data with the main
/// image. That's usually a JPEG, but HEIF and WebP files can carry the same
/// EXIF block, thumbnail included, and are checked the same way. Cameras and phones generate that thumbnail once, at capture. An
/// editor that changes the main image but carries the old EXIF block along
/// unchanged leaves a thumbnail that no longer matches, and so does a file
/// assembled from two sources.
///
/// The thumbnail comes from IFD1 via the same `ExifReader` metadata
/// analysis uses, and is decoded with `BaselineJPEGDecoder` (luminance
/// only). A JPEG main image is decoded the same way, at 1/8 scale whenever
/// that's still at least as large as the thumbnail, which skips nearly all
/// of the decoding work; a HEIF or WebP main image is already decoded, and
/// its pixels are used directly. Black letterbox bars in the thumbnail are trimmed. The main image
/// is resampled to the thumbnail's content size, and `ThumbnailSimilarity`
/// scores the pair. Two separately labeled signals come out of it:
///
/// - **Content mismatch:** similarity below `similarityThreshold`. The
///   pictures differ: something was added, removed, or replaced. Scores 60
///   to 90, and points at the least similar part of the image.
/// - **Aspect-ratio mismatch:** the thumbnail's shape differs from the main
///   image's by more than `aspectRatioTolerance`. The image was reframed
///   (cropped, or extended) after capture. Content is then compared against
///   a centered crop of the thumbnail with the main image's shape, which
///   matches a centered crop but not an off-center one. Scores 35, because
///   cropping is an ordinary, usually innocent edit.
///
/// This is a single whole-image check, not a per-block map: there's one
/// thumbnail and one comparison, and at most the one least-similar region to
/// report.
///
/// **Not applicable** (score 0, with the reason in the summary) when the
/// file isn't a JPEG, HEIF, or WebP file, has no EXIF data, or has no
/// embedded EXIF thumbnail (common: many tools strip it, and HEIF files
/// usually store their thumbnail as a separate HEVC image instead, which
/// this check doesn't read). Also when the thumbnail is uncompressed TIFF data
/// (rare, unsupported), corrupt or truncated, either image can't be decoded
/// (e.g. a progressive JPEG), or both images are featureless.
///
/// **Limitations.** A supporting signal, not proof. Software that
/// regenerates the thumbnail on every save (many editors and phone galleries
/// do) leaves a matching thumbnail however much the image was edited. A
/// mismatch only shows the main image changed after the thumbnail was made,
/// and benign tools (re-exporters, batch converters, some RAW workflows)
/// can do that too. Edits only a few thumbnail pixels across are below what
/// a thumbnail can resolve: a 32px object in a 512px-wide image with a 64px
/// thumbnail went unflagged in testing, while a 64px one was caught.
public struct ThumbnailConsistencyAnalyzer: Analyzer {
    public let identifier = "thumbnail"
    public let displayName = "EXIF Thumbnail Consistency"

    /// Largest `|ln(aspect ratio)|` difference treated as the same shape:
    /// about 4%, comfortably above integer rounding of a small thumbnail's
    /// dimensions (160x107 for 3:2 is off by 0.3%).
    static let aspectRatioTolerance = 0.04

    /// The thumbnail content must be at least this many pixels on each side.
    static let minimumThumbnailSide = 8

    static let aspectMismatchScore = 35.0

    public init() {}

    public func analyze(_ image: ImageData, config: ForensicLensConfig) throws -> AnalyzerFinding {
        let threshold = config.thumbnail.similarityThreshold
        func notApplicable(_ reason: String) -> AnalyzerFinding {
            AnalyzerFinding.clean(analyzerID: identifier, summary: "\(reason) EXIF thumbnail consistency is not applicable.")
        }

        guard let format = image.format, format.canCarryEXIF else {
            return notApplicable("Only JPEG files (and HEIF or WebP files with EXIF metadata) carry an EXIF thumbnail, and this is a \(image.format?.displayName ?? "non-JPEG") file.")
        }
        guard let exif = ExifReader.read(from: image.rawBytes) else {
            return notApplicable("The file has no EXIF data.")
        }
        guard let thumbnail = exif.thumbnail else {
            return notApplicable("The file has no embedded EXIF thumbnail.")
        }
        guard let thumbnailJPEG = thumbnail.jpegData else {
            return notApplicable(thumbnail.compression == 1
                ? "The EXIF thumbnail is stored uncompressed, which this check doesn't support."
                : "The EXIF thumbnail's location in the file is missing or invalid.")
        }

        let thumbnailPlane: PRNUPlane
        do {
            thumbnailPlane = PRNUPlane.luminance(of: try BaselineJPEGDecoder.decode(thumbnailJPEG, output: .luminance))
        } catch {
            return notApplicable("The EXIF thumbnail couldn't be decoded (\(error)).")
        }

        let content = ThumbnailSimilarity.contentRegion(of: thumbnailPlane)
        guard content.width >= Self.minimumThumbnailSide, content.height >= Self.minimumThumbnailSide else {
            return notApplicable("The EXIF thumbnail is too small (\(content.width)x\(content.height) px of content) to compare.")
        }

        let main: (plane: PRNUPlane, width: Int, height: Int)
        do {
            main = try mainImage(image, atLeast: content)
        } catch {
            return notApplicable("The main image couldn't be decoded (\(error)).")
        }

        let aspectDifference = ThumbnailSimilarity.aspectRatioDifference(width: main.width, height: main.height, otherWidth: content.width, otherHeight: content.height)
        let aspectMismatch = aspectDifference > Self.aspectRatioTolerance
        let compared = aspectMismatch
            ? ThumbnailSimilarity.centeredRegion(withAspect: main.width, main.height, in: content)
            : content
        let thumbnailCompared = thumbnailPlane.cropped(to: compared)
        let mainCompared = ThumbnailSimilarity.resample(main.plane, toWidth: compared.width, height: compared.height)

        guard let comparison = ThumbnailSimilarity.compare(mainCompared, thumbnailCompared) else {
            return notApplicable("Both the thumbnail and the main image are featureless, so there's nothing to compare.")
        }

        let similarity = comparison.similarity
        let similarityText = String(format: "%.2f", similarity)
        let detail = "global correlation \(comparison.global.map { String(format: "%.2f", $0) } ?? "n/a"), lowest of \(comparison.cellsCompared) grid cell(s) \(comparison.worstCell.map { String(format: "%.2f", $0) } ?? "n/a")"
        let thumbnailSize = "\(thumbnailPlane.width)x\(thumbnailPlane.height)"
        var indicators: [Indicator] = []
        var score = 0.0
        var summaryParts: [String] = []

        if similarity < threshold {
            let contentScore = 60 + 30 * min(1, (threshold - similarity) / max(threshold, 0.01))
            score = max(score, contentScore)
            let regions = comparison.worstCellRegion.map { [mainRegion(for: $0, compared: compared, mainWidth: main.width, mainHeight: main.height)] } ?? []
            indicators.append(Indicator(
                message: "Content mismatch: the \(thumbnailSize) EXIF thumbnail doesn't match the main image (similarity \(similarityText), threshold \(String(format: "%.2f", threshold)); \(detail)). The main image was likely edited after the thumbnail was generated, or the file was assembled from two sources. The marked area differs most.",
                weight: contentScore,
                regions: regions
            ))
            summaryParts.append("The EXIF thumbnail's content doesn't match the main image (similarity \(similarityText)), suggesting the image was edited after capture.")
        }

        if aspectMismatch {
            score = max(score, Self.aspectMismatchScore)
            let shape = "\(content.width)x\(content.height) px of thumbnail content versus a \(main.width)x\(main.height) main image"
            indicators.append(Indicator(
                message: "Aspect-ratio mismatch: \(shape) (ratio differs by \(String(format: "%.0f", (exp(aspectDifference) - 1) * 100))%). The image was reframed or cropped after the thumbnail was generated. Content was compared against a centered crop of the thumbnail\(similarity < threshold ? "" : ", and matches it (similarity \(similarityText))").",
                weight: Self.aspectMismatchScore
            ))
            summaryParts.append("The EXIF thumbnail has a different aspect ratio than the main image, suggesting it was cropped or reframed after capture.")
        }

        guard !summaryParts.isEmpty else {
            return AnalyzerFinding.clean(
                analyzerID: identifier,
                summary: "The \(thumbnailSize) EXIF thumbnail matches the main image (similarity \(similarityText), threshold \(String(format: "%.2f", threshold)))."
            )
        }
        return AnalyzerFinding(analyzerID: identifier, score: score, summary: summaryParts.joined(separator: " "), indicators: indicators)
    }

    /// The main image's luminance (at full or 1/8 scale) and its full
    /// dimensions. Uses already-decoded pixels if `image` has them; otherwise
    /// decodes `image.rawBytes`, at 1/8 scale when that's still at least as
    /// large as the thumbnail content `atLeast`.
    private func mainImage(_ image: ImageData, atLeast content: Region) throws -> (plane: PRNUPlane, width: Int, height: Int) {
        if let pixels = image.pixels {
            return (PRNUPlane.luminance(of: pixels), pixels.width, pixels.height)
        }
        let frame = try BaselineJPEGDecoder.frameInfo(image.rawBytes)
        let eighthIsEnough = frame.width / 8 >= content.width && frame.height / 8 >= content.height
        let decoded = try BaselineJPEGDecoder.decode(image.rawBytes, scale: eighthIsEnough ? .eighth : .full, output: .luminance)
        return (PRNUPlane.luminance(of: decoded), frame.width, frame.height)
    }

    /// Maps a cell of the compared grid (thumbnail-sized, covering the whole
    /// main image) to main-image pixel coordinates.
    private func mainRegion(for cell: Region, compared: Region, mainWidth: Int, mainHeight: Int) -> Region {
        let scaleX = Double(mainWidth) / Double(max(1, compared.width))
        let scaleY = Double(mainHeight) / Double(max(1, compared.height))
        let x = Int((Double(cell.x) * scaleX).rounded(.down))
        let y = Int((Double(cell.y) * scaleY).rounded(.down))
        let right = min(mainWidth, Int((Double(cell.x + cell.width) * scaleX).rounded(.up)))
        let bottom = min(mainHeight, Int((Double(cell.y + cell.height) * scaleY).rounded(.up)))
        return Region(x: x, y: y, width: max(0, right - x), height: max(0, bottom - y))
    }
}
