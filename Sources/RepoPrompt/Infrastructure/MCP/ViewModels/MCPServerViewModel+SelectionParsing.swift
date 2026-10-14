import Foundation
import MCP

extension MCPServerViewModel {
    struct ManageSelectionInputs {
        let paths: [String]
        let sliceInputs: [WorkspaceSelectionSliceInput]
        let sliceErrors: [String]
        let hadExplicitSliceSpec: Bool
    }

    private enum SliceRangeEndpoint {
        case line(Int)
        case missing
        case notInteger
    }

    nonisolated static func isLineRangeSuffix(_ suffix: Substring) -> Bool {
        guard let first = suffix.first, first == "L" || first == "l" else { return false }
        let remainder = suffix.dropFirst()
        guard !remainder.isEmpty else { return false }
        let sanitized = remainder.filter { !$0.isWhitespace }
        guard let firstDigit = sanitized.first, firstDigit.isNumber else { return false }
        let allowed = CharacterSet(charactersIn: "0123456789,-;")
        for scalar in sanitized.unicodeScalars where !allowed.contains(scalar) {
            return false
        }
        return true
    }

    nonisolated static func parseManageSelectionInputs(rawPaths: [String], slicesValue: Value?) -> ManageSelectionInputs {
        var sanitizedPaths: [String] = []
        var seenPaths = Set<String>()
        var sliceInputs: [WorkspaceSelectionSliceInput] = []
        var sliceErrors: [String] = []
        var hadExplicitSlices = false

        for raw in rawPaths {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            var pathComponent = trimmed
            var ranges: [LineRange] = []

            if let hashIndex = trimmed.lastIndex(of: "#") {
                let suffixStart = trimmed.index(after: hashIndex)
                if suffixStart < trimmed.endIndex {
                    let suffix = String(trimmed[suffixStart...])
                    if Self.isLineRangeSuffix(trimmed[suffixStart...]) {
                        hadExplicitSlices = true
                        let base = String(trimmed[..<hashIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !base.isEmpty {
                            pathComponent = base
                        }
                        let payload = String(suffix.dropFirst())
                        let (parsed, invalidTokens) = Self.parseLineRangeTokens(from: payload)
                        ranges.append(contentsOf: parsed)
                        sliceErrors.append(contentsOf: invalidTokens.map { Self.shorthandTokenDiagnostic(token: $0, path: trimmed) })
                    }
                }
            }

            if !seenPaths.contains(pathComponent) {
                sanitizedPaths.append(pathComponent)
                seenPaths.insert(pathComponent)
            }

            if !ranges.isEmpty {
                sliceInputs.append(.init(path: pathComponent, ranges: ranges))
            }
        }

        if let slicesValue, !slicesValue.isNull, slicesValue.arrayValue == nil {
            sliceErrors.append("Invalid slices: expected an array of {path, ranges: [{start_line, end_line}]}.")
        }

        if let slicesArray = slicesValue?.arrayValue {
            if !slicesArray.isEmpty {
                hadExplicitSlices = true
            }
            for entry in slicesArray {
                guard let obj = entry.objectValue else {
                    sliceErrors.append("Invalid slice: each slice must be an object {path, ranges: [{start_line, end_line}]}.")
                    continue
                }
                let rawPath = obj["path"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !rawPath.isEmpty else {
                    sliceErrors.append("Invalid slice: path is required; expected {path, ranges: [{start_line, end_line}]}.")
                    continue
                }

                // A slice can hold several ranges and a `lines` string, so an endpoint beside `path`
                // cannot be assigned to any one of them.
                let misplacedKeys = ["start_line", "end_line", "start", "end"].filter { obj[$0] != nil }
                guard misplacedKeys.isEmpty else {
                    sliceErrors.append(
                        "Invalid slice for path '\(rawPath)': \(misplacedKeys.joined(separator: ", ")) must be inside ranges: [{start_line, end_line}], not beside path."
                    )
                    continue
                }

                if let rangesValue = obj["ranges"], !rangesValue.isNull, rangesValue.arrayValue == nil {
                    sliceErrors.append(
                        "Invalid slice for path '\(rawPath)': ranges must be an array; expected ranges: [{start_line, end_line}]."
                    )
                    continue
                }
                if let linesValue = obj["lines"], !linesValue.isNull, linesValue.stringValue == nil {
                    sliceErrors.append(
                        "Invalid slice for path '\(rawPath)': lines must be a string such as '10-20,40', or use ranges: [{start_line, end_line}]."
                    )
                    continue
                }

                var ranges: [LineRange] = []
                var explicitRangeSpecified = false

                if let rangesArray = obj["ranges"]?.arrayValue {
                    explicitRangeSpecified = true
                    for value in rangesArray {
                        // A skipped item would leave `ranges` empty, which `remove` reads as every slice of the file.
                        guard let rangeObj = value.objectValue else {
                            sliceErrors.append(Self.sliceRangeDiagnostic(path: rawPath, problem: "each range must be an object"))
                            continue
                        }
                        let start = Self.sliceRangeEndpoint(rangeObj, key: "start_line", alias: "start")
                        let end = Self.sliceRangeEndpoint(rangeObj, key: "end_line", alias: "end")
                        // `LineRange` clamps a start below 1 to 1 and a reversed range to one line, so both are
                        // rejected here.
                        switch (start, end) {
                        case let (.line(startLine), _) where startLine < 1:
                            sliceErrors.append(Self.sliceRangeDiagnostic(path: rawPath, problem: "start_line must be at least 1"))
                        case let (.line(startLine), .line(endLine)) where endLine >= startLine:
                            ranges.append(LineRange(start: startLine, end: endLine, description: Self.sliceRangeDescription(rangeObj)))
                        case (.line, .line):
                            sliceErrors.append(Self.sliceRangeDiagnostic(path: rawPath, problem: "end_line must be greater than or equal to start_line"))
                        case (.missing, _):
                            sliceErrors.append(Self.sliceRangeDiagnostic(path: rawPath, problem: "start_line is required"))
                        case (.notInteger, _):
                            sliceErrors.append(Self.sliceRangeDiagnostic(path: rawPath, problem: "start_line must be an integer"))
                        case (.line, .missing):
                            sliceErrors.append(Self.sliceRangeDiagnostic(path: rawPath, problem: "end_line is required"))
                        case (.line, .notInteger):
                            sliceErrors.append(Self.sliceRangeDiagnostic(path: rawPath, problem: "end_line must be an integer"))
                        }
                    }
                }

                if let linesString = obj["lines"]?.stringValue {
                    explicitRangeSpecified = true
                    let (parsed, invalidTokens) = Self.parseLineRangeTokens(from: linesString)
                    // A `lines` value with no tokens, such as "," or " ", would also reach `remove` as an
                    // empty range list.
                    if parsed.isEmpty, invalidTokens.isEmpty {
                        sliceErrors.append(
                            "Invalid slice for path '\(rawPath)': lines must list at least one line or range, such as '10-20,40'."
                        )
                    }
                    ranges.append(contentsOf: parsed)
                    sliceErrors.append(contentsOf: invalidTokens.map { Self.shorthandTokenDiagnostic(token: $0, path: rawPath) })
                }

                if explicitRangeSpecified {
                    sliceInputs.append(.init(path: rawPath, ranges: ranges))
                }
            }
        }

        return ManageSelectionInputs(
            paths: sanitizedPaths,
            sliceInputs: sliceInputs,
            sliceErrors: sliceErrors,
            hadExplicitSliceSpec: hadExplicitSlices || !sliceInputs.isEmpty
        )
    }

    /// Reads `key`, or `alias` only when `key` is absent, so an invalid canonical value is reported
    /// instead of being replaced by a valid alias value.
    private nonisolated static func sliceRangeEndpoint(
        _ range: [String: Value],
        key: String,
        alias: String
    ) -> SliceRangeEndpoint {
        guard let value = range[key] ?? range[alias] else { return .missing }
        if let line = value.intValue ?? value.stringValue.flatMap({ Int($0) }) {
            return .line(line)
        }
        return .notInteger
    }

    private nonisolated static func sliceRangeDescription(_ range: [String: Value]) -> String? {
        let rawDescription = range["description"]?.stringValue
            ?? range["desc"]?.stringValue
            ?? range["label"]?.stringValue
        let trimmedDescription = rawDescription?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmedDescription?.isEmpty == false) ? trimmedDescription : nil
    }

    private nonisolated static func sliceRangeDiagnostic(path: String, problem: String) -> String {
        "Invalid slice range for path '\(path)': \(problem); expected ranges: [{start_line, end_line}]."
    }

    private nonisolated static func shorthandTokenDiagnostic(token: String, path: String) -> String {
        "Invalid slice '\(token)' for path '\(path)': use a 1-based line or a closed range, or ranges: [{start_line, end_line}]."
    }

    nonisolated static func parseLineRangeTokens(from text: String) -> ([LineRange], [String]) {
        let compact = text
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\t", with: "")
            .replacingOccurrences(of: " ", with: "")
        guard !compact.isEmpty else { return ([], []) }

        let rawTokens = compact.split { ",;".contains($0) }
        var ranges: [LineRange] = []
        var invalid: [String] = []

        for rawToken in rawTokens {
            var token = String(rawToken)
            if token.isEmpty { continue }
            if token.lowercased().hasPrefix("l") {
                token.removeFirst()
            }
            if token.isEmpty {
                invalid.append(String(rawToken))
                continue
            }

            if let dashIndex = token.firstIndex(of: "-") {
                let startPart = String(token[..<dashIndex])
                let endPart = String(token[token.index(after: dashIndex)...])
                if let start = Int(startPart), let end = Int(endPart), start >= 1, end >= start {
                    ranges.append(LineRange(start: start, end: end))
                } else {
                    invalid.append(String(rawToken))
                }
            } else if let value = Int(token), value >= 1 {
                ranges.append(LineRange(start: value, end: value))
            } else {
                invalid.append(String(rawToken))
            }
        }

        return (ranges, invalid)
    }
}
