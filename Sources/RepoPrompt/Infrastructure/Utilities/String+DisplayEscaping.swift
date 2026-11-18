import Foundation

extension String {
    /// A copy of this string with the characters escaped that could make a person or an agent misread it. Use it on
    /// text that a repository or a tool supplied, such as a Codex hook's key, path, matcher, or command, when that text
    /// is shown. It is for display only: keep the original for identity, selection, and writes.
    ///
    /// Each line break, meaning a `Character` whose `isNewline` is true, becomes `\n`, so a value can't start a line of
    /// its own and pass as another entry. Every other scalar that is invisible or reorders text becomes `\u{XXXX}`:
    /// the controls (general category Cc), the format characters (Cf), and the variation selectors. Cf covers the bidi
    /// controls, which can make text read differently from what it holds, and the zero-width, joiner, soft hyphen, and
    /// tag characters, which a person can't see but an agent reads. With `keepingLineBreaksAndTabs`, line breaks and
    /// tabs stay as they are, for text that a view shows over several lines; everything else is escaped the same way.
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
        // The variation selectors are nonspacing marks, and the tag block holds unassigned scalars beside its Cf ones,
        // so no general category covers them.
        case 0xFE00 ... 0xFE0F, 0xE0000 ... 0xE007F, 0xE0100 ... 0xE01EF:
            true
        default:
            properties.generalCategory == .control || properties.generalCategory == .format
        }
    }
}
