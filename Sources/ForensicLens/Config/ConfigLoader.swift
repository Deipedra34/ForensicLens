import Foundation

/// Errors surfaced while reading or parsing `forensiclens.yaml`.
public enum ConfigError: Error, Equatable, CustomStringConvertible {
    /// A line couldn't be parsed as either a section header or a `key: value` pair.
    case malformedLine(number: Int, text: String)

    /// A key was recognized but its value couldn't be converted to the
    /// expected type (e.g. `qualityLevel: banana`).
    case invalidValue(key: String, value: String)

    /// A key appeared under a section that doesn't have a slot for it.
    case unknownKey(section: String, key: String)

    public var description: String {
        switch self {
        case .malformedLine(let number, let text):
            return "Could not parse line \(number): \"\(text)\""
        case .invalidValue(let key, let value):
            return "Invalid value for \"\(key)\": \"\(value)\""
        case .unknownKey(let section, let key):
            return "Unknown config key \"\(key)\" under section \"\(section)\""
        }
    }
}

/// Loads `ForensicLensConfig` from a YAML file.
///
/// This is not a general-purpose YAML implementation. Pulling in a full
/// YAML parser (or an external dependency) for a config file with three
/// flat sections would be a lot of machinery for very little payoff, and
/// it'd work against the whole "no dependencies, builds offline" point of
/// this project. So instead it reads the small subset of YAML the shipped
/// `forensiclens.yaml` actually uses: two-space-indented `key: value`
/// pairs grouped under top-level section headers, scalar values (bools,
/// numbers, strings), and inline `[a, b, c]` lists. Comments (`#`) and
/// blank lines are ignored. Anything outside that subset gets reported as
/// a typed `ConfigError` rather than silently ignored or guessed at.
public enum ConfigLoader {
    /// Parses `yaml`, applying its values on top of `ForensicLensConfig.default`
    /// so a config file only needs to mention the keys it wants to override.
    public static func parse(_ yaml: String) throws -> ForensicLensConfig {
        var config = ForensicLensConfig.default
        var currentSection: String?

        for (index, rawLine) in yaml.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let lineNumber = index + 1
            let withoutComment = stripComment(String(rawLine))
            guard !withoutComment.trimmingWhitespace().isEmpty else { continue }

            let indent = withoutComment.prefix(while: { $0 == " " }).count

            if indent == 0 {
                // Section header: "ela:", "metadata:", "cloneDetection:"
                let trimmed = withoutComment.trimmingWhitespace()
                guard trimmed.hasSuffix(":") else {
                    throw ConfigError.malformedLine(number: lineNumber, text: rawLine.description)
                }
                currentSection = String(trimmed.dropLast())
                continue
            }

            guard let section = currentSection else {
                throw ConfigError.malformedLine(number: lineNumber, text: rawLine.description)
            }
            guard let (key, value) = splitKeyValue(withoutComment.trimmingWhitespace()) else {
                throw ConfigError.malformedLine(number: lineNumber, text: rawLine.description)
            }

            try apply(section: section, key: key, value: value, to: &config)
        }

        return config
    }

    /// Loads and parses a config file from disk. If no file exists at
    /// `path`, returns `ForensicLensConfig.default` rather than throwing --
    /// a missing config file is a normal, expected way to run ForensicLens
    /// with defaults, not an error.
    public static func load(contentsOfFile path: String) throws -> ForensicLensConfig {
        guard FileManager.default.fileExists(atPath: path) else {
            return ForensicLensConfig.default
        }
        let text = try String(contentsOfFile: path, encoding: .utf8)
        return try parse(text)
    }

    private static func stripComment(_ line: String) -> String {
        guard let hashIndex = line.firstIndex(of: "#") else { return line }
        // A '#' inside a quoted string would need smarter handling; the
        // shipped config never quotes a value containing '#', so a simple
        // cut is sufficient here.
        return String(line[line.startIndex..<hashIndex])
    }

    private static func splitKeyValue(_ line: String) -> (key: String, value: String)? {
        guard let colonIndex = line.firstIndex(of: ":") else { return nil }
        let key = line[line.startIndex..<colonIndex].trimmingWhitespace()
        let value = line[line.index(after: colonIndex)...].trimmingWhitespace()
        guard !key.isEmpty else { return nil }
        return (key, value)
    }

    private static func apply(section: String, key: String, value: String, to config: inout ForensicLensConfig) throws {
        switch section {
        case "ela":
            try applyELA(key: key, value: value, to: &config.ela)
        case "metadata":
            try applyMetadata(key: key, value: value, to: &config.metadata)
        case "cloneDetection":
            try applyCloneDetection(key: key, value: value, to: &config.cloneDetection)
        default:
            throw ConfigError.unknownKey(section: section, key: key)
        }
    }

    private static func applyELA(key: String, value: String, to ela: inout ForensicLensConfig.ELAConfig) throws {
        switch key {
        case "enabled":
            ela.enabled = try parseBool(key: key, value: value)
        case "qualityLevel":
            ela.qualityLevel = try parseInt(key: key, value: value)
        case "errorThreshold":
            ela.errorThreshold = try parseDouble(key: key, value: value)
        case "flaggedRegionFraction":
            ela.flaggedRegionFraction = try parseDouble(key: key, value: value)
        default:
            throw ConfigError.unknownKey(section: "ela", key: key)
        }
    }

    private static func applyMetadata(key: String, value: String, to metadata: inout ForensicLensConfig.MetadataConfig) throws {
        switch key {
        case "enabled":
            metadata.enabled = try parseBool(key: key, value: value)
        case "flagMissingExif":
            metadata.flagMissingExif = try parseBool(key: key, value: value)
        case "suspiciousSoftwareKeywords":
            metadata.suspiciousSoftwareKeywords = try parseStringList(key: key, value: value)
        case "maxTimestampDriftSeconds":
            metadata.maxTimestampDriftSeconds = try parseInt(key: key, value: value)
        case "maxGPSTimestampDriftSeconds":
            metadata.maxGPSTimestampDriftSeconds = try parseInt(key: key, value: value)
        case "maxDigitizedDriftSeconds":
            metadata.maxDigitizedDriftSeconds = try parseInt(key: key, value: value)
        default:
            throw ConfigError.unknownKey(section: "metadata", key: key)
        }
    }

    private static func applyCloneDetection(key: String, value: String, to clone: inout ForensicLensConfig.CloneDetectionConfig) throws {
        switch key {
        case "enabled":
            clone.enabled = try parseBool(key: key, value: value)
        case "blockSize":
            clone.blockSize = try parseInt(key: key, value: value)
        case "blockStride":
            clone.blockStride = try parseInt(key: key, value: value)
        case "minimumBlockVariance":
            clone.minimumBlockVariance = try parseDouble(key: key, value: value)
        case "similarityThreshold":
            clone.similarityThreshold = try parseDouble(key: key, value: value)
        case "minimumBlockDistance":
            clone.minimumBlockDistance = try parseInt(key: key, value: value)
        default:
            throw ConfigError.unknownKey(section: "cloneDetection", key: key)
        }
    }

    private static func parseBool(key: String, value: String) throws -> Bool {
        switch value.lowercased() {
        case "true", "yes": return true
        case "false", "no": return false
        default: throw ConfigError.invalidValue(key: key, value: value)
        }
    }

    private static func parseInt(key: String, value: String) throws -> Int {
        guard let parsed = Int(value) else {
            throw ConfigError.invalidValue(key: key, value: value)
        }
        return parsed
    }

    private static func parseDouble(key: String, value: String) throws -> Double {
        guard let parsed = Double(value) else {
            throw ConfigError.invalidValue(key: key, value: value)
        }
        return parsed
    }

    private static func parseStringList(key: String, value: String) throws -> [String] {
        var trimmed = value.trimmingWhitespace()
        guard trimmed.hasPrefix("["), trimmed.hasSuffix("]") else {
            throw ConfigError.invalidValue(key: key, value: value)
        }
        trimmed.removeFirst()
        trimmed.removeLast()
        guard !trimmed.trimmingWhitespace().isEmpty else { return [] }
        return trimmed.split(separator: ",").map { entry in
            var item = entry.trimmingWhitespace()
            if item.hasPrefix("\""), item.hasSuffix("\""), item.count >= 2 {
                item.removeFirst()
                item.removeLast()
            }
            return item
        }
    }
}

extension String {
    /// Trims leading and trailing ASCII whitespace.
    func trimmingWhitespace() -> String {
        var start = startIndex
        var end = endIndex
        while start < end, self[start] == " " || self[start] == "\t" || self[start] == "\r" {
            start = index(after: start)
        }
        while end > start {
            let before = index(before: end)
            if self[before] == " " || self[before] == "\t" || self[before] == "\r" {
                end = before
            } else {
                break
            }
        }
        return String(self[start..<end])
    }
}

extension Substring {
    func trimmingWhitespace() -> String {
        String(self).trimmingWhitespace()
    }
}
