import Foundation

extension String {
    /// A copy of this string with the characters escaped that could make a person or an agent misread it. Use it on
    /// text that a repository or a tool supplied, such as a Codex hook's key, path, matcher, or command, when that text
    /// is shown. It is for display only: keep the original for identity, selection, and writes.
    ///
    /// Each line break, meaning a `Character` whose `isNewline` is true, becomes `\n`, so a value can't start a line of
    /// its own and pass as another entry. Every other C0 or C1 control character, and the bidi formatting characters
    /// U+061C, U+200E, U+200F, U+202A-U+202E, and U+2066-U+2069, become `\u{XXXX}`, because a bidi control can make
    /// text read differently from what it holds. With `keepingLineBreaksAndTabs`, line breaks and tabs stay as they
    /// are, for text that a view shows over several lines; everything else is escaped the same way.
    func escapedForDisplay(keepingLineBreaksAndTabs: Bool = false) -> String {
        var escaped = ""
        for character in self {
            if character.isNewline {
                if keepingLineBreaksAndTabs {
                    escaped.append(character)
                } else {
                    escaped += "\\n"
                }
                continue
            }
            for scalar in character.unicodeScalars {
                let keepsScalar = keepingLineBreaksAndTabs && scalar == "\t"
                if !keepsScalar, scalar.isEscapedForDisplay {
                    escaped += String(format: "\\u{%04X}", scalar.value)
                } else {
                    escaped.unicodeScalars.append(scalar)
                }
            }
        }
        return escaped
    }
}

private extension Unicode.Scalar {
    var isEscapedForDisplay: Bool {
        switch value {
        case 0x061C, 0x200E, 0x200F, 0x202A ... 0x202E, 0x2066 ... 0x2069:
            true
        default:
            properties.generalCategory == .control
        }
    }
}
