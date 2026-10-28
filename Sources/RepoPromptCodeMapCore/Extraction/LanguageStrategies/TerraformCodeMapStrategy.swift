import Foundation
import SwiftTreeSitter

/// A Terraform tree that can't yield trustworthy facts: a recovery tree, a missing node, a root that
/// isn't native Terraform syntax, or a string escape HCL rejects. The engine reports it as
/// `.parseFailed(.invalidTerraformSyntax)`.
struct TerraformCodeMapSyntaxError: Error, Equatable {
    let reason: String
}

/// Copies Terraform declarations out of a parsed HCL tree. It runs synchronously on the caller's
/// tree, and only immutable values leave it.
enum TerraformCodeMapStrategy {
    /// Body attributes of a module call that configure the call rather than pass an input.
    fileprivate static let moduleMetaArgumentNames: Set<String> = [
        "source", "version", "count", "for_each", "providers", "depends_on", "ignore_nested_deprecations"
    ]

    static func extract(root: Node, content: String) throws -> TerraformCodeMapArtifact {
        guard !root.hasError else {
            throw TerraformCodeMapSyntaxError(reason: "the parser recovered from a syntax error")
        }
        var walker = Walker(source: SourceText(content: content))
        for child in syntaxChildren(of: root) {
            switch child.nodeType {
            case "body":
                for item in syntaxChildren(of: child) {
                    switch item.nodeType {
                    case "block":
                        try walker.walkTopLevelBlock(item)
                    case "attribute":
                        try walker.validateTopLevelAttribute(item)
                    default:
                        throw TerraformCodeMapSyntaxError(reason: "unexpected top-level node")
                    }
                }
            case "object":
                // The grammar also accepts a JSON-style object root, which isn't native Terraform.
                throw TerraformCodeMapSyntaxError(reason: "the file is a JSON-style object")
            default:
                throw TerraformCodeMapSyntaxError(reason: "unexpected root node")
            }
        }
        return TerraformCodeMapArtifact(declarations: walker.declarations, references: [])
    }

    /// Children other than comments, which the grammar allows between any two tokens.
    fileprivate static func syntaxChildren(of node: Node) -> [Node] {
        (0 ..< node.childCount).compactMap { node.child(at: $0) }.filter { !$0.isExtra }
    }
}

// MARK: - Walk

private struct Walker {
    /// A subtree under a top-level block that the walk has yet to visit. `inQuotedTemplate` is true
    /// when the nearest enclosing template is a quoted string, where HCL processes backslash
    /// escapes; a heredoc keeps them as literal text.
    struct Frame {
        let node: Node
        let inQuotedTemplate: Bool
    }

    struct Attribute {
        let name: String
        let node: Node
        let expression: Node
    }

    let source: SourceText
    private(set) var declarations: [TerraformCodeMapDeclaration] = []

    init(source: SourceText) {
        self.source = source
    }

    /// Reads one top-level block's header and direct body items, then visits every node below them.
    mutating func walkTopLevelBlock(_ block: Node) throws {
        var blockType: String?
        var labels: [String] = []
        var attributes: [Attribute] = []
        var hasSourceBlock = false
        var subtrees: [Frame] = []

        for child in TerraformCodeMapStrategy.syntaxChildren(of: block) {
            try requirePresent(child)
            switch child.nodeType {
            case "identifier" where blockType == nil:
                blockType = source.text(of: child)
            case "identifier":
                labels.append(source.text(of: child))
            case "string_lit":
                try labels.append(source.decodedStringLiteral(child))
            case "block_start", "block_end":
                continue
            case "body":
                for item in TerraformCodeMapStrategy.syntaxChildren(of: child) {
                    try requirePresent(item)
                    switch item.nodeType {
                    case "attribute":
                        let attribute = try readAttribute(item)
                        attributes.append(attribute)
                        subtrees.append(Frame(node: attribute.expression, inQuotedTemplate: false))
                    case "block":
                        // Always read the header: a source block must not skip validating later nested blocks.
                        let nestedName = try nestedBlockName(item)
                        hasSourceBlock = hasSourceBlock || nestedName == "source"
                        subtrees.append(Frame(node: item, inQuotedTemplate: false))
                    default:
                        throw TerraformCodeMapSyntaxError(reason: "unexpected block body item")
                    }
                }
            default:
                throw TerraformCodeMapSyntaxError(reason: "unexpected block header node")
            }
        }
        guard let blockType else { throw TerraformCodeMapSyntaxError(reason: "block without a type") }
        try visit(subtrees)

        try declarations.append(contentsOf: makeDeclarations(
            blockType: blockType,
            labels: labels,
            lineNumber: source.lineNumber(of: block),
            attributes: attributes,
            hasSourceBlock: hasSourceBlock
        ))
    }

    /// Checks a top-level attribute's syntax without taking facts from it. Terraform rejects
    /// top-level arguments, so they declare and reference nothing, but an invalid escape or missing
    /// node in one still makes the file invalid HCL.
    mutating func validateTopLevelAttribute(_ attribute: Node) throws {
        try requirePresent(attribute)
        try visit([Frame(node: readAttribute(attribute).expression, inQuotedTemplate: false)])
    }

    /// Visits every node below the given subtrees once with an explicit stack, so nesting depth in
    /// the source never deepens the call stack.
    private mutating func visit(_ subtrees: [Frame]) throws {
        var stack = subtrees
        while let frame = stack.popLast() {
            let node = frame.node
            try requirePresent(node)
            let nodeType = node.nodeType
            if nodeType == "template_literal", frame.inQuotedTemplate {
                // HCL rejects an invalid escape in any quoted string, including values the outline omits.
                _ = try SourceText.decodedQuotedText(source.text(of: node))
            }
            let childrenInQuotedTemplate = switch nodeType {
            case "string_lit", "quoted_template": true
            case "heredoc_template": false
            default: frame.inQuotedTemplate
            }
            for index in (0 ..< node.childCount).reversed() {
                if let child = node.child(at: index) {
                    stack.append(Frame(node: child, inQuotedTemplate: childrenInQuotedTemplate))
                }
            }
        }
    }

    private func makeDeclarations(
        blockType: String,
        labels: [String],
        lineNumber: Int,
        attributes: [Attribute],
        hasSourceBlock: Bool
    ) throws -> [TerraformCodeMapDeclaration] {
        let recognizedKind: TerraformDeclarationKind? = switch blockType {
        case "variable": .variable
        case "output": .output
        case "module": .module
        case "resource": .resource
        case "data": .data
        case "locals": .local
        default: nil
        }
        // A `locals` block has no labels; each of its attributes becomes a local named by one label.
        let blockLabelCount = recognizedKind == .local ? 0 : recognizedKind?.requiredLabelCount
        // Unknown kinds keep the attributes the outline retains for their block type. A known
        // kind with the wrong label count, or an empty `locals` block, keeps only its header,
        // because the outline retains no attribute for those block types under `other`.
        let kind: TerraformDeclarationKind
        if let recognizedKind, labels.count == blockLabelCount, recognizedKind != .local || !attributes.isEmpty {
            kind = recognizedKind
        } else {
            kind = .other
        }

        if kind == .local {
            return try attributes.map { attribute in
                try TerraformCodeMapDeclaration(
                    kind: .local,
                    blockType: blockType,
                    labels: [attribute.name],
                    lineNumber: source.lineNumber(of: attribute.node)
                )
            }
        }
        return try [TerraformCodeMapDeclaration(
            kind: kind,
            blockType: blockType,
            labels: labels,
            lineNumber: lineNumber,
            attributes: outlineAttributes(attributes, kind: kind, blockType: blockType),
            hasDefault: kind == .variable && attributes.contains { $0.name == "default" },
            moduleSource: kind == .module ? moduleSource(attributes: attributes, hasSourceBlock: hasSourceBlock) : nil,
            argumentNames: kind == .module
                ? attributes.map(\.name).filter { !TerraformCodeMapStrategy.moduleMetaArgumentNames.contains($0) }
                : []
        )]
    }

    private func outlineAttributes(
        _ attributes: [Attribute],
        kind: TerraformDeclarationKind,
        blockType: String
    ) -> [TerraformOutlineAttribute] {
        let retained = TerraformCodeMapDeclaration.outlineAttributeNames(kind: kind, blockType: blockType)
        return attributes.filter { retained.contains($0.name) }.map { attribute in
            TerraformOutlineAttribute(name: attribute.name, valueText: source.outlineText(of: attribute.expression))
        }
    }

    /// Classifies a module call's `source`. A nested `source` block, or more than one source
    /// definition, can't name a single module folder.
    private func moduleSource(attributes: [Attribute], hasSourceBlock: Bool) throws -> TerraformModuleSource {
        let sources = attributes.filter { $0.name == "source" }
        guard !hasSourceBlock else { return .invalid }
        guard let source = sources.first else { return .missing }
        guard sources.count == 1 else { return .invalid }
        guard let literal = staticStringLiteral(in: source.expression) else { return .nonLiteral }
        return try .literal(self.source.decodedStringLiteral(literal))
    }

    /// The `string_lit` node when the expression is exactly one static string, without templates,
    /// operators, or parentheses.
    private func staticStringLiteral(in expression: Node) -> Node? {
        let terms = TerraformCodeMapStrategy.syntaxChildren(of: expression)
        guard terms.count == 1, terms[0].nodeType == "literal_value" else { return nil }
        let values = TerraformCodeMapStrategy.syntaxChildren(of: terms[0])
        guard values.count == 1, values[0].nodeType == "string_lit" else { return nil }
        return values[0]
    }

    private func readAttribute(_ attribute: Node) throws -> Attribute {
        let children = TerraformCodeMapStrategy.syntaxChildren(of: attribute)
        guard let name = children.first, name.nodeType == "identifier",
              let expression = children.last, expression.nodeType == "expression"
        else {
            throw TerraformCodeMapSyntaxError(reason: "malformed attribute")
        }
        return Attribute(name: source.text(of: name), node: attribute, expression: expression)
    }

    private func nestedBlockName(_ block: Node) throws -> String {
        guard let name = TerraformCodeMapStrategy.syntaxChildren(of: block).first,
              name.nodeType == "identifier"
        else {
            throw TerraformCodeMapSyntaxError(reason: "block without a type")
        }
        return source.text(of: name)
    }

    private func requirePresent(_ node: Node) throws {
        guard !node.isMissing else { throw TerraformCodeMapSyntaxError(reason: "missing syntax node") }
    }
}

// MARK: - Source text

/// Reads node text and line numbers through the UTF-16 ranges the wrapper reports, which match
/// `NSString` offsets because the engine parses UTF-16 text.
private struct SourceText {
    private let text: NSString
    private let lineBoundaries: [Int]

    init(content: String) {
        text = content as NSString
        lineBoundaries = CodeMapGenerator.computeLineBoundaries(content: content)
    }

    func text(of node: Node) -> String {
        let range = node.range
        guard range.location != NSNotFound, NSMaxRange(range) <= text.length else { return "" }
        return text.substring(with: range)
    }

    func lineNumber(of node: Node) -> Int {
        CodeMapGenerator.lineNumber(for: node.range.location, using: lineBoundaries)
    }

    /// Expression text for the outline: LF line endings and no surrounding whitespace. Inner
    /// whitespace, indentation, and string contents stay as written.
    func outlineText(of expression: Node) -> String {
        text(of: expression)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func decodedStringLiteral(_ literal: Node) throws -> String {
        let parts = TerraformCodeMapStrategy.syntaxChildren(of: literal)
        guard let chunk = parts.first(where: { $0.nodeType == "template_literal" }) else { return "" }
        return try Self.decodedQuotedText(text(of: chunk))
    }

    /// Decodes the literal text of a quoted string or quoted template with HCL's escapes: `\n`,
    /// `\r`, `\t`, `\"`, `\\`, `\uXXXX`, `\UXXXXXXXX`, `$${`, and `%%{`. HCL rejects an escape
    /// naming a value that isn't a Unicode scalar, so this does too.
    static func decodedQuotedText(_ raw: String) throws -> String {
        var decoded = String.UnicodeScalarView()
        var remaining = raw.unicodeScalars[...]
        while let scalar = remaining.popFirst() {
            switch scalar {
            case "\\":
                guard let selector = remaining.popFirst() else {
                    throw TerraformCodeMapSyntaxError(reason: "unterminated escape")
                }
                switch selector {
                case "n": decoded.append("\n")
                case "r": decoded.append("\r")
                case "t": decoded.append("\t")
                case "\"", "\\": decoded.append(selector)
                case "u": try decoded.append(Self.hexScalar(digitCount: 4, from: &remaining))
                case "U": try decoded.append(Self.hexScalar(digitCount: 8, from: &remaining))
                default: throw TerraformCodeMapSyntaxError(reason: "invalid escape selector")
                }
            case "$", "%":
                // `$${` and `%%{` are escapes for a literal `${` and `%{`.
                if remaining.first == scalar, remaining.dropFirst().first == "{" {
                    remaining.removeFirst()
                }
                decoded.append(scalar)
            default:
                decoded.append(scalar)
            }
        }
        return String(decoded)
    }

    private static func hexScalar(
        digitCount: Int,
        from remaining: inout Substring.UnicodeScalarView
    ) throws -> Unicode.Scalar {
        let digits = remaining.prefix(digitCount)
        guard digits.count == digitCount, digits.allSatisfy(\.properties.isASCIIHexDigit),
              let value = UInt32(String(String.UnicodeScalarView(digits)), radix: 16),
              let scalar = Unicode.Scalar(value)
        else {
            throw TerraformCodeMapSyntaxError(reason: "invalid Unicode escape")
        }
        remaining.removeFirst(digitCount)
        return scalar
    }
}
