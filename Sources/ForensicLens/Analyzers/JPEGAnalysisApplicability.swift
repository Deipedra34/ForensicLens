import ImageDecoding

extension ImageFormat {
    /// Why JPEG-specific analysis -- Error Level Analysis, JPEG ghost
    /// detection, and double-compression detection -- doesn't apply to
    /// this format, or `nil` if it does.
    ///
    /// Those three analyzers model JPEG's 8x8 DCT quantization: how pixels
    /// respond to a fresh JPEG save, or what an earlier one left behind.
    /// HEIF/HEIC (HEVC) and lossy WebP (VP8) are compressed differently --
    /// other block sizes and transforms, plus in-loop deblocking -- and
    /// lossless WebP isn't lossy at all. Run on those, the analyzers would
    /// measure codec artifacts rather than edits, so they report "not
    /// applicable" instead of a score.
    ///
    /// Uncompressed formats (BMP, PPM/PGM) keep running them: such a file is
    /// often a JPEG decoded and re-saved, so it can still carry a JPEG
    /// compression history.
    var jpegAnalysisNotApplicableReason: String? {
        switch self {
        case .heif:
            return "HEIF/HEIC images are compressed with HEVC, not JPEG, so there's no JPEG compression history to analyze"
        case .webp:
            return "WebP images are compressed with VP8 (or stored losslessly), not JPEG, so there's no JPEG compression history to analyze"
        case .bmp, .ppm, .pgm, .jpeg:
            return nil
        }
    }
}

extension AnalyzerFinding {
    /// The clean finding a JPEG-specific analyzer reports for a format it
    /// doesn't apply to (see `ImageFormat.jpegAnalysisNotApplicableReason`).
    static func jpegAnalysisNotApplicable(analyzerID: String, displayName: String, reason: String) -> AnalyzerFinding {
        .clean(analyzerID: analyzerID, summary: "\(reason); \(displayName) is not applicable.")
    }
}
