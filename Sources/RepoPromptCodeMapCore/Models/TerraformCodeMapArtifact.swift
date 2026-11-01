import Foundation

// MARK: - Terraform source-derived facts

/// A top-level Terraform declaration, classified by its block keyword. Recognized blocks whose label
/// count doesn't fit their kind are `other`, so they render as headers and define no graph symbol.
package enum TerraformDeclarationKind: String, Codable, Hashable, Sendable {
    case variable
    case output
    case module
    case resource
    case data
    case local
    case other

    /// The block keyword a declaration of this kind comes from; `other` keeps whatever keyword it had.
    var requiredBlockType: String? {
        switch self {
        case .variable: "variable"
        case .output: "output"
        case .module: "module"
        case .resource: "resource"
        case .data: "data"
        case .local: "locals"
        case .other: nil
        }
    }

    var requiredLabelCount: Int? {
        switch self {
        case .variable, .output, .module, .local: 1
        case .resource, .data: 2
        case .other: nil
        }
    }
}

package enum TerraformReferenceKind: String, Codable, Hashable, Sendable {
    case variable
    case local
    case resource
    case data
    case moduleCall
    case moduleOutput

    var requiredPartCount: Int {
        switch self {
        case .variable, .local, .moduleCall: 1
        case .resource, .data, .moduleOutput: 2
        }
    }
}

/// An authored attribute retained for the outline, limited to the names in
/// `TerraformCodeMapDeclaration.outlineAttributeNames(kind:blockType:)`. `valueText` is the
/// attribute's expression with line endings normalized and outer whitespace trimmed.
package struct TerraformOutlineAttribute: Codable, Hashable, Sendable {
    package let name: String
    package let valueText: String

    package init(name: String, valueText: String) {
        self.name = name
        self.valueText = valueText
    }
}

package enum TerraformModuleSourceKind: String, Codable, Hashable, Sendable {
    case literal
    case nonLiteral
    case missing
    case invalid
}

/// How a module call's `source` attribute was written. Only a single static string literal
/// carries a value; an empty literal stays a literal.
package enum TerraformModuleSource: Codable, Hashable, Sendable {
    case literal(String)
    case nonLiteral
    case missing
    case invalid

    private enum CodingKeys: String, CodingKey { case kind, value }

    package var kind: TerraformModuleSourceKind {
        switch self {
        case .literal: .literal
        case .nonLiteral: .nonLiteral
        case .missing: .missing
        case .invalid: .invalid
        }
    }

    package var literalValue: String? {
        if case let .literal(value) = self { return value }
        return nil
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(TerraformModuleSourceKind.self, forKey: .kind)
        if kind != .literal, container.contains(.value) {
            throw DecodingError.dataCorruptedError(
                forKey: .value,
                in: container,
                debugDescription: "Only a literal module source has a value."
            )
        }
        switch kind {
        case .literal: self = try .literal(container.decode(String.self, forKey: .value))
        case .nonLiteral: self = .nonLiteral
        case .missing: self = .missing
        case .invalid: self = .invalid
        }
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        if let literalValue {
            try container.encode(literalValue, forKey: .value)
        }
    }
}

package enum TerraformCodeMapArtifactError: Error, Equatable, Sendable {
    case blockTypeMismatch
    case invalidLabelCount
    case invalidLineNumber
    case defaultOutsideVariable
    case moduleSourceMismatch
    case argumentNamesOutsideModule
    case attributeNotAllowed
    case invalidReferencePartCount
    case emptyName
    case nonCanonicalNames
}

package struct TerraformCodeMapDeclaration: Codable, Hashable, Sendable {
    package let kind: TerraformDeclarationKind
    package let blockType: String
    package let labels: [String]
    /// One-based line of the block header, or of the attribute for a `local`.
    package let lineNumber: Int
    package let attributes: [TerraformOutlineAttribute]
    package let hasDefault: Bool
    /// Present exactly when `kind` is `module`.
    package let moduleSource: TerraformModuleSource?
    /// The module call's input names in canonical order (see `TerraformCanonicalNames`).
    package let argumentNames: [String]

    private enum CodingKeys: String, CodingKey {
        case kind, blockType, labels, lineNumber, attributes, hasDefault, moduleSource, argumentNames
    }

    package init(
        kind: TerraformDeclarationKind,
        blockType: String,
        labels: [String],
        lineNumber: Int,
        attributes: [TerraformOutlineAttribute] = [],
        hasDefault: Bool = false,
        moduleSource: TerraformModuleSource? = nil,
        argumentNames: [String] = []
    ) throws {
        if let requiredBlockType = kind.requiredBlockType, blockType != requiredBlockType {
            throw TerraformCodeMapArtifactError.blockTypeMismatch
        }
        if let requiredLabelCount = kind.requiredLabelCount, labels.count != requiredLabelCount {
            throw TerraformCodeMapArtifactError.invalidLabelCount
        }
        guard lineNumber >= 1 else { throw TerraformCodeMapArtifactError.invalidLineNumber }
        guard kind == .variable || !hasDefault else { throw TerraformCodeMapArtifactError.defaultOutsideVariable }
        guard (kind == .module) == (moduleSource != nil) else {
            throw TerraformCodeMapArtifactError.moduleSourceMismatch
        }
        guard kind == .module || argumentNames.isEmpty else {
            throw TerraformCodeMapArtifactError.argumentNamesOutsideModule
        }
        guard argumentNames.allSatisfy({ !$0.isEmpty }) else { throw TerraformCodeMapArtifactError.emptyName }
        let allowedAttributeNames = Self.outlineAttributeNames(kind: kind, blockType: blockType)
        guard attributes.allSatisfy({ allowedAttributeNames.contains($0.name) }) else {
            throw TerraformCodeMapArtifactError.attributeNotAllowed
        }

        self.kind = kind
        self.blockType = blockType
        self.labels = labels
        self.lineNumber = lineNumber
        self.attributes = attributes
        self.hasDefault = hasDefault
        self.moduleSource = moduleSource
        self.argumentNames = TerraformCanonicalNames.sortedUnique(argumentNames)
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let argumentNames = try container.decode([String].self, forKey: .argumentNames)
        try self.init(
            kind: container.decode(TerraformDeclarationKind.self, forKey: .kind),
            blockType: container.decode(String.self, forKey: .blockType),
            labels: container.decode([String].self, forKey: .labels),
            lineNumber: container.decode(Int.self, forKey: .lineNumber),
            attributes: container.decode([TerraformOutlineAttribute].self, forKey: .attributes),
            hasDefault: container.decode(Bool.self, forKey: .hasDefault),
            moduleSource: container.decode(TerraformModuleSource?.self, forKey: .moduleSource),
            argumentNames: argumentNames
        )
        guard TerraformCanonicalNames.haveSameBytes(self.argumentNames, argumentNames) else {
            throw TerraformCodeMapArtifactError.nonCanonicalNames
        }
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(blockType, forKey: .blockType)
        try container.encode(labels, forKey: .labels)
        try container.encode(lineNumber, forKey: .lineNumber)
        try container.encode(attributes, forKey: .attributes)
        try container.encode(hasDefault, forKey: .hasDefault)
        try container.encode(moduleSource, forKey: .moduleSource)
        try container.encode(argumentNames, forKey: .argumentNames)
    }

    /// The attributes the outline may retain for a declaration. Everything else, including default
    /// values, descriptions, validations, value bodies, import IDs, and backend settings, stays out
    /// of the persisted artifact. A module's source and inputs have their own fields; a `local`, and
    /// an `other` block whose type isn't listed here, keep no attributes. A name may repeat, because
    /// a duplicate attribute still parses and the outline shows each occurrence.
    static func outlineAttributeNames(kind: TerraformDeclarationKind, blockType: String) -> Set<String> {
        switch kind {
        case .variable: ["type", "sensitive", "nullable", "ephemeral", "const"]
        case .output: ["sensitive", "ephemeral"]
        case .module: ["version", "count", "for_each"]
        case .resource, .data: ["count", "for_each", "provider"]
        case .local: []
        case .other:
            switch blockType {
            case "terraform": ["required_version"]
            case "provider": ["alias"]
            case "moved": ["from", "to"]
            case "import": ["to"]
            case "removed": ["from"]
            default: []
            }
        }
    }
}

package struct TerraformCodeMapReference: Codable, Hashable, Sendable {
    package let kind: TerraformReferenceKind
    /// The reference's names in NFC, for example `[callName, outputName]` for `moduleOutput`.
    package let parts: [String]

    private enum CodingKeys: String, CodingKey { case kind, parts }

    package init(kind: TerraformReferenceKind, parts: [String]) throws {
        guard parts.count == kind.requiredPartCount else {
            throw TerraformCodeMapArtifactError.invalidReferencePartCount
        }
        guard parts.allSatisfy({ !$0.isEmpty }) else { throw TerraformCodeMapArtifactError.emptyName }
        self.kind = kind
        self.parts = parts.map(\.precomposedStringWithCanonicalMapping)
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let parts = try container.decode([String].self, forKey: .parts)
        try self.init(kind: container.decode(TerraformReferenceKind.self, forKey: .kind), parts: parts)
        guard TerraformCanonicalNames.haveSameBytes(self.parts, parts) else {
            throw TerraformCodeMapArtifactError.nonCanonicalNames
        }
    }

    fileprivate static func precedes(_ lhs: Self, _ rhs: Self) -> Bool {
        if lhs.kind != rhs.kind {
            return TerraformCanonicalNames.precedes(lhs.kind.rawValue, rhs.kind.rawValue)
        }
        return lhs.parts.lexicographicallyPrecedes(rhs.parts, by: TerraformCanonicalNames.precedes)
    }
}

/// The Terraform facts of one `.tf` file. Declarations keep source order; references are unique and
/// sorted by kind and then parts, each compared by UTF-8 bytes.
package struct TerraformCodeMapArtifact: Codable, Hashable, Sendable {
    package let declarations: [TerraformCodeMapDeclaration]
    package let references: [TerraformCodeMapReference]

    private enum CodingKeys: String, CodingKey { case declarations, references }

    package init(declarations: [TerraformCodeMapDeclaration], references: [TerraformCodeMapReference]) {
        self.declarations = declarations
        self.references = Array(Set(references)).sorted(by: TerraformCodeMapReference.precedes)
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let references = try container.decode([TerraformCodeMapReference].self, forKey: .references)
        try self.init(
            declarations: container.decode([TerraformCodeMapDeclaration].self, forKey: .declarations),
            references: references
        )
        // Every decoded part is already NFC, so equality here is byte equality.
        guard self.references == references else { throw TerraformCodeMapArtifactError.nonCanonicalNames }
    }
}

/// Case-preserving NFC names ordered by UTF-8 bytes. Swift's `String` equality and ordering follow
/// canonical equivalence, so canonical order is defined on bytes to stay stable across normal forms.
enum TerraformCanonicalNames {
    static func sortedUnique(_ names: [String]) -> [String] {
        Array(Set(names.map(\.precomposedStringWithCanonicalMapping))).sorted(by: precedes)
    }

    static func precedes(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }

    static func haveSameBytes(_ lhs: [String], _ rhs: [String]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { $0.utf8.elementsEqual($1.utf8) }
    }
}

// MARK: - Path-free Terraform outline

package enum TerraformCodeMapFormatter {
    private static let declarationPrefix = "  - "
    private static let detailPrefix = "      "

    package static func render(_ artifact: TerraformCodeMapArtifact) -> String {
        var lines = ["---", "Terraform:"]
        if artifact.declarations.isEmpty {
            lines.append("  (no declarations)")
        }
        for declaration in artifact.declarations {
            append(declaration, to: &lines)
        }
        lines.append("---")
        return "\n" + lines.joined(separator: "\n") + "\n"
    }

    private static func append(_ declaration: TerraformCodeMapDeclaration, to lines: inout [String]) {
        var header = "L\(declaration.lineNumber): \(headerText(declaration))"
        var details = declaration.attributes
        if declaration.kind == .variable {
            if let typeIndex = details.firstIndex(where: { $0.name == "type" }) {
                header += ": " + details.remove(at: typeIndex).valueText
            }
            header += declaration.hasDefault ? " [default present; value omitted]" : " [required]"
        }
        appendValue(header, prefix: declarationPrefix, to: &lines)

        if let source = declaration.moduleSource {
            lines.append(detailPrefix + "source: " + sourceText(source))
        }
        for attribute in details {
            appendValue("\(attribute.name): \(attribute.valueText)", prefix: detailPrefix, to: &lines)
        }
        if !declaration.argumentNames.isEmpty {
            lines.append(detailPrefix + "inputs: " + declaration.argumentNames.joined(separator: ", "))
        }
    }

    private static func headerText(_ declaration: TerraformCodeMapDeclaration) -> String {
        if declaration.kind == .local, let name = declaration.labels.first {
            return "local.\(name)"
        }
        return ([declaration.blockType] + declaration.labels.map(quoted)).joined(separator: " ")
    }

    private static func sourceText(_ source: TerraformModuleSource) -> String {
        switch source {
        case let .literal(value): quoted(value)
        case .nonLiteral: "[non-literal]"
        case .missing: "[missing]"
        case .invalid: "[invalid]"
        }
    }

    /// Indents every continuation line of a multiline value by the width of its first line's
    /// prefix, so retained source indentation stays visible under its bullet.
    private static func appendValue(_ text: String, prefix: String, to lines: inout [String]) {
        let continuationPrefix = String(repeating: " ", count: prefix.count)
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            lines.append((index == 0 ? prefix : continuationPrefix) + line)
        }
    }

    /// Quotes a decoded label or source literal so separators and line breaks inside it stay
    /// visible on a single outline line.
    private static func quoted(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case _ where scalar.value < 0x20: result += String(format: "\\u%04X", scalar.value)
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }
}
