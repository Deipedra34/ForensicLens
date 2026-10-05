import Foundation
import BatchProcessing

/// One image in an evaluation dataset, paired with its ground truth.
struct LabeledImage: Equatable, Sendable {
    let path: String
    let label: GroundTruth
}

/// The two dataset layouts `forensiclens-eval` understands.
enum DatasetLayout: Equatable {
    /// A root directory containing `authentic/` and `tampered/`
    /// subdirectories. Each is scanned recursively.
    case folders(root: String)

    /// A CSV file with one `path,label` row per image.
    case manifest(path: String)
}

/// Errors raised while locating or reading a dataset. Every case carries
/// enough context to tell the user what to fix, since a malformed layout
/// is the most likely thing to go wrong on a first run.
enum DatasetError: Error, Equatable, CustomStringConvertible {
    case notFound(String)
    case missingClassDirectory(root: String, name: String)
    case noImages(directory: String, extensions: [String])
    case unreadableManifest(String)
    case emptyManifest(String)
    case malformedManifestLine(manifest: String, line: Int, content: String)
    case unknownLabel(manifest: String, line: Int, label: String)
    case conflictingLabels(path: String)

    var description: String {
        switch self {
        case .notFound(let path):
            return "dataset path \"\(path)\" does not exist."
        case .missingClassDirectory(let root, let name):
            return "dataset directory \"\(root)\" has no \"\(name)/\" subdirectory. "
                + "Expected layout: <root>/\(DatasetLoader.authenticDirectoryName)/ and <root>/\(DatasetLoader.tamperedDirectoryName)/, "
                + "or pass a CSV manifest (path,label) instead."
        case .noImages(let directory, let extensions):
            return "no images found under \"\(directory)\" (extensions: \(extensions.joined(separator: ", "))). "
                + "Use --extensions to change which files are picked up."
        case .unreadableManifest(let path):
            return "could not read manifest \"\(path)\"."
        case .emptyManifest(let path):
            return "manifest \"\(path)\" lists no images."
        case .malformedManifestLine(let manifest, let line, let content):
            return "\(manifest):\(line): expected \"path,label\", got \"\(content)\"."
        case .unknownLabel(let manifest, let line, let label):
            return "\(manifest):\(line): unknown label \"\(label)\". "
                + "Use authentic (or au, real, 0) / tampered (or tp, forged, fake, 1)."
        case .conflictingLabels(let path):
            return "\"\(path)\" is listed more than once with different labels."
        }
    }
}

/// Turns a `--dataset` path into a list of labeled images.
///
/// Only walks the local filesystem -- this never fetches anything over the
/// network. Datasets such as CASIA have to be obtained and placed on disk
/// by the user under their own license.
enum DatasetLoader {
    static let authenticDirectoryName = "authentic"
    static let tamperedDirectoryName = "tampered"

    /// A directory means the folder layout; a regular file means a CSV
    /// manifest.
    static func detectLayout(at path: String) throws -> DatasetLayout {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            throw DatasetError.notFound(path)
        }
        return isDirectory.boolValue ? .folders(root: path) : .manifest(path: path)
    }

    /// - Parameter extensions: Lowercased file extensions to treat as
    ///   images in the folder layout. A manifest lists its files
    ///   explicitly, so this filter doesn't apply to it.
    static func load(_ layout: DatasetLayout, extensions: Set<String>) throws -> [LabeledImage] {
        switch layout {
        case .folders(let root):
            return try loadFolders(root: root, extensions: extensions)
        case .manifest(let path):
            guard let data = FileManager.default.contents(atPath: path) else {
                throw DatasetError.unreadableManifest(path)
            }
            let baseDirectory = (path as NSString).deletingLastPathComponent
            return try parseManifest(String(decoding: data, as: UTF8.self), manifestName: path, baseDirectory: baseDirectory)
        }
    }

    // MARK: - Folder layout

    private static func loadFolders(root: String, extensions: Set<String>) throws -> [LabeledImage] {
        let scanner = BatchFileScanner(extensions: extensions, recursive: true)
        var images: [LabeledImage] = []

        for (name, label) in [(authenticDirectoryName, GroundTruth.authentic), (tamperedDirectoryName, .tampered)] {
            let directory = (root as NSString).appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw DatasetError.missingClassDirectory(root: root, name: name)
            }
            let files = try scanner.scanFiles(in: directory)
            guard !files.isEmpty else {
                throw DatasetError.noImages(directory: directory, extensions: extensions.sorted())
            }
            images.append(contentsOf: files.map { LabeledImage(path: $0, label: label) })
        }
        return images
    }

    // MARK: - CSV manifest

    /// Parses `path,label` rows. Blank lines and lines starting with `#`
    /// are ignored, as is a leading `path,label` header row. Paths may be
    /// double-quoted (for paths containing commas); relative paths are
    /// resolved against `baseDirectory`, the manifest's own directory.
    static func parseManifest(_ contents: String, manifestName: String, baseDirectory: String) throws -> [LabeledImage] {
        var images: [LabeledImage] = []
        var seen: [String: GroundTruth] = [:]

        let lines = contents.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        for (index, rawLine) in lines.enumerated() {
            let lineNumber = index + 1
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            guard let fields = splitCSVRow(line), fields.count == 2, !fields[0].isEmpty else {
                throw DatasetError.malformedManifestLine(manifest: manifestName, line: lineNumber, content: line)
            }
            let rawPath = fields[0]
            let rawLabel = fields[1]

            if images.isEmpty, seen.isEmpty, rawPath.lowercased() == "path", rawLabel.lowercased() == "label" {
                continue
            }
            guard let label = parseLabel(rawLabel) else {
                throw DatasetError.unknownLabel(manifest: manifestName, line: lineNumber, label: rawLabel)
            }

            let path = (rawPath as NSString).isAbsolutePath
                ? rawPath
                : (baseDirectory as NSString).appendingPathComponent(rawPath)

            if let existing = seen[path] {
                guard existing == label else { throw DatasetError.conflictingLabels(path: path) }
                continue
            }
            seen[path] = label
            images.append(LabeledImage(path: path, label: label))
        }

        guard !images.isEmpty else { throw DatasetError.emptyManifest(manifestName) }
        return images
    }

    /// Accepts this project's own label names plus the common aliases
    /// other datasets use -- including CASIA's `Au` / `Tp` filename
    /// prefixes -- case-insensitively.
    static func parseLabel(_ raw: String) -> GroundTruth? {
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "authentic", "au", "real", "original", "pristine", "0":
            return .authentic
        case "tampered", "tp", "forged", "fake", "manipulated", "1":
            return .tampered
        default:
            return nil
        }
    }

    /// Splits one CSV row on commas, honoring double-quoted fields (with
    /// `""` as an escaped quote). Returns `nil` for an unterminated quote.
    private static func splitCSVRow(_ line: String) -> [String]? {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        let characters = Array(line)
        var index = 0

        while index < characters.count {
            let character = characters[index]
            index += 1
            if inQuotes {
                if character == "\"" {
                    if index < characters.count, characters[index] == "\"" {
                        current.append("\"")
                        index += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    current.append(character)
                }
            } else if character == "\"" {
                inQuotes = true
            } else if character == "," {
                fields.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        guard !inQuotes else { return nil }
        fields.append(current.trimmingCharacters(in: .whitespaces))
        return fields
    }
}
