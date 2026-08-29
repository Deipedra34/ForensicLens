import Foundation

/// Errors raised while walking a directory for the `batch` command.
enum BatchScanError: Error, CustomStringConvertible {
    case directoryNotFound(String)

    var description: String {
        switch self {
        case .directoryNotFound(let path):
            return "\"\(path)\" is not a directory or does not exist."
        }
    }
}

/// Walks a directory tree looking for files whose extension matches a
/// configured allow-list.
///
/// Everything here goes through `FileManager`, never a platform-specific
/// API, so recursive and non-recursive scans behave the same way on macOS
/// and Linux. This type only ever deals with paths on disk -- it has no
/// idea what `ImageData` or `Analyzer` are -- which is also why it lives in
/// the CLI target and not in `ForensicLens` itself: directory walking is a
/// concern of "the CLI reads a folder", not of the analysis library.
struct BatchFileScanner: Sendable {
    /// Lowercased extensions (without the leading dot) to treat as images.
    let extensions: Set<String>

    /// Whether to walk into subdirectories or only look at the top level.
    let recursive: Bool

    /// Returns every matching file path under `directory`, sorted for
    /// deterministic output.
    ///
    /// - Throws: `BatchScanError.directoryNotFound` if `directory` doesn't
    ///   exist or isn't a directory.
    func scanFiles(in directory: String) throws -> [String] {
        let fileManager = FileManager.default

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw BatchScanError.directoryNotFound(directory)
        }

        let candidatePaths: [String]
        if recursive {
            guard let enumerator = fileManager.enumerator(atPath: directory) else {
                throw BatchScanError.directoryNotFound(directory)
            }
            candidatePaths = enumerator.compactMap { $0 as? String }
                .map { (directory as NSString).appendingPathComponent($0) }
        } else {
            candidatePaths = try fileManager.contentsOfDirectory(atPath: directory)
                .map { (directory as NSString).appendingPathComponent($0) }
        }

        return candidatePaths
            .filter(isMatchingFile)
            .sorted()
    }

    private func isMatchingFile(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return false
        }
        let ext = (path as NSString).pathExtension.lowercased()
        return extensions.contains(ext)
    }
}
