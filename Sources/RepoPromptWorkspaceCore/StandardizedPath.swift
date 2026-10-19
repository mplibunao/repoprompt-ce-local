import Foundation

private let standardizedPathSlashTrim = CharacterSet(charactersIn: "/")
private let standardizedPathSlash = UInt8(ascii: "/")
private let standardizedPathDot = UInt8(ascii: ".")
/// `NSString.standardizingPath` truncates a path longer than 1,024 UTF-16 code units.
/// A UTF-8 byte count within this bound keeps the UTF-16 count within it too.
private let standardizingPathMaximumUTF8Count = 1024
/// Prefixes `NSString.standardizingPath` removes when the shorter path exists on disk.
private let standardizingPathRemovablePrefixes = ["/private", "/var/automount"]

package enum StandardizedPath {
    /// Returns the same bytes as `NSString.standardizingPath`. It returns `path` itself when the
    /// text alone shows standardizing would change nothing, so a caller that stores both the input
    /// and the result keeps one string instead of two.
    @inline(__always)
    package static func absolute(_ path: String) -> String {
        isUnchangedByStandardizing(path) ? path : (path as NSString).standardizingPath
    }

    @inline(__always)
    package static func relative(_ path: String) -> String {
        if hasOnlyPlainComponents(path.utf8[...]) { return path }

        let trimmed = path.trimmingCharacters(in: standardizedPathSlashTrim)
        guard !trimmed.isEmpty, trimmed != "." else { return "" }

        var components: [Substring] = []
        components.reserveCapacity(trimmed.split(separator: "/", omittingEmptySubsequences: true).count)
        for component in trimmed.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                if let last = components.last, last != ".." {
                    components.removeLast()
                } else {
                    components.append(component)
                }
            default:
                components.append(component)
            }
        }
        return components.map(String.init).joined(separator: "/")
    }

    /// Whether the text alone shows `NSString.standardizingPath` would return `path` unchanged.
    /// That holds for an absolute path, which can't start with `~`, that has no removable
    /// prefix, no more bytes than standardizing keeps, and only plain components. Any other
    /// path goes to Foundation, including one it might shorten after checking the disk.
    private static func isUnchangedByStandardizing(_ path: String) -> Bool {
        let bytes = path.utf8
        guard bytes.count <= standardizingPathMaximumUTF8Count,
              bytes.first == standardizedPathSlash,
              !standardizingPathRemovablePrefixes.contains(where: { bytes.starts(with: $0.utf8) })
        else { return false }
        return hasOnlyPlainComponents(bytes.dropFirst())
    }

    /// Whether `bytes` is one or more `/`-separated components, none of them empty, `.`, or `..`,
    /// which also rules out a leading, trailing, or doubled slash.
    private static func hasOnlyPlainComponents(_ bytes: Substring.UTF8View) -> Bool {
        var componentLength = 0
        var componentIsAllDots = true
        for byte in bytes {
            if byte == standardizedPathSlash {
                guard isPlainComponent(length: componentLength, isAllDots: componentIsAllDots) else { return false }
                componentLength = 0
                componentIsAllDots = true
            } else {
                componentLength += 1
                componentIsAllDots = componentIsAllDots && byte == standardizedPathDot
            }
        }
        return isPlainComponent(length: componentLength, isAllDots: componentIsAllDots)
    }

    @inline(__always)
    private static func isPlainComponent(length: Int, isAllDots: Bool) -> Bool {
        length > 0 && !(isAllDots && length <= 2)
    }

    @inline(__always)
    package static func join(standardizedRoot: String, standardizedRelativePath: String) -> String {
        guard !standardizedRelativePath.isEmpty else { return standardizedRoot }
        return standardizedRoot.hasSuffix("/")
            ? standardizedRoot + standardizedRelativePath
            : standardizedRoot + "/" + standardizedRelativePath
    }

    @inline(__always)
    package static func containsNUL(_ path: String) -> Bool {
        path.unicodeScalars.contains { $0.value == 0 }
    }

    package static func diagnosticEscaped(_ path: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(path.count)
        for scalar in path.unicodeScalars {
            switch scalar.value {
            case 0:
                escaped += "\\0"
            case 8:
                escaped += "\\b"
            case 9:
                escaped += "\\t"
            case 10:
                escaped += "\\n"
            case 12:
                escaped += "\\f"
            case 13:
                escaped += "\\r"
            case 0x1B:
                escaped += "\\e"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    escaped += "\\u{" + String(scalar.value, radix: 16, uppercase: true) + "}"
                } else {
                    escaped.unicodeScalars.append(scalar)
                }
            }
        }
        return escaped
    }

    @inline(__always)
    package static func isDescendant(_ standardizedPath: String, of standardizedParent: String) -> Bool {
        if standardizedPath == standardizedParent { return true }
        let prefix = standardizedParent.hasSuffix("/") ? standardizedParent : standardizedParent + "/"
        return standardizedPath.hasPrefix(prefix)
    }
}
