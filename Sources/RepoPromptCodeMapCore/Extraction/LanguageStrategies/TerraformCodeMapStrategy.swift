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

    /// Root names that never name a declaration in this folder: iteration and object context,
    /// path and workspace values, and ephemeral resources and actions, which the outline keeps as
    /// `other`.
    fileprivate static let nonDeclarationRoots: Set<String> = [
        "each", "count", "self", "path", "terraform", "ephemeral", "action"
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
        return TerraformCodeMapArtifact(declarations: walker.declarations, references: walker.references)
    }

    /// Children other than comments, which the grammar allows between any two tokens.
    fileprivate static func syntaxChildren(of node: Node) -> [Node] {
        (0 ..< node.childCount).compactMap { node.child(at: $0) }.filter { !$0.isExtra }
    }

    /// How a block's direct attribute reads references. `parentBlockType` is the type of the block
    /// whose body holds this one, or nil for a top-level block. A `provider` or `providers`
    /// meta-argument selects provider configurations, not resources, and the only nested block
    /// that takes one is a `data` block scoped to a `check`. A type constraint, `ignore_changes`
    /// attribute paths, and a dynamic block's `iterator`, which declares a name, aren't references
    /// either. An `import` target and both ends of a `moved` block are object addresses; a move can
    /// relocate one instance of a resource that stays declared. A `removed` source is an address
    /// too, but Terraform requires the object it names to be absent from the configuration.
    fileprivate static func referenceReading(
        blockType: String,
        parentBlockType: String?,
        attributeName: String
    ) -> Walker.ReferenceReading {
        switch (parentBlockType, blockType, attributeName) {
        case (nil, "resource", "provider"), (nil, "data", "provider"), (nil, "ephemeral", "provider"),
             (nil, "action", "provider"), (nil, "import", "provider"), ("check", "data", "provider"),
             (nil, "module", "providers"), (nil, "variable", "type"),
             (_, "lifecycle", "ignore_changes"), (_, "dynamic", "iterator"):
            .skipped
        case (nil, "import", "to"), (nil, "moved", "from"), (nil, "moved", "to"):
            .address
        case (nil, "removed", "from"):
            .removedAddress
        default:
            .expressions
        }
    }
}

// MARK: - Walk

private struct Walker {
    /// A subtree under a top-level block that the walk has yet to visit, with the context its
    /// position gives it.
    struct Frame {
        let node: Node
        /// True when the nearest enclosing template is a quoted string, where HCL processes
        /// backslash escapes; a heredoc keeps them as literal text.
        let inQuotedTemplate: Bool
        /// How the traversals among this node's children are read.
        let reading: ReferenceReading
        /// For a nested block, the type of the block whose body holds it, which the walk has
        /// already read; nil for every other node.
        let parentBlockType: String?

        static func root(_ node: Node, reading: ReferenceReading, parentBlockType: String? = nil) -> Frame {
            Frame(node: node, inQuotedTemplate: false, reading: reading, parentBlockType: parentBlockType)
        }

        /// A frame for a child node: this frame's context with the child's reading. Nothing below a
        /// skipped subtree is read.
        func child(
            _ node: Node,
            inQuotedTemplate: Bool,
            reading: ReferenceReading = .expressions,
            parentBlockType: String? = nil
        ) -> Frame {
            Frame(
                node: node,
                inQuotedTemplate: inQuotedTemplate,
                reading: self.reading == .skipped ? .skipped : reading,
                parentBlockType: parentBlockType
            )
        }
    }

    /// One step of the walk: a subtree to visit, or the start or end of a lexical scope. A scope's
    /// entries enclose the frames its binders cover, so the walk visits those subtrees, and only
    /// those, while the binders are active.
    enum StackEntry {
        case frame(Frame)
        case enterScope([String])
        case exitScope([String])

        /// Entries that visit `frames` with `names` bound around them.
        static func scope(_ names: [String], around frames: [Frame]) -> [StackEntry] {
            let visits = frames.map(StackEntry.frame)
            return names.isEmpty ? visits : [.enterScope(names)] + visits + [.exitScope(names)]
        }
    }

    /// How a frame reads the traversals among its node's children.
    enum ReferenceReading {
        /// Nothing in the subtree names a declaration in this folder.
        case skipped
        case expressions
        /// An object address, such as an `import` target. It names a resource or a module call, and
        /// what follows a call is a path inside the child module, not an output. Instance keys
        /// inside the address are read as expressions.
        case address
        /// The address of an object a `removed` block deletes. The object is gone from the
        /// configuration, but a module call the address passes through still exists. Instance
        /// keys inside the address are read as expressions.
        case removedAddress
    }

    struct Attribute {
        let name: String
        let node: Node
        let expression: Node
    }

    /// One step after a traversal's root name.
    enum TraversalStep {
        case attribute(String)
        /// An index or splat, which selects instances or elements without naming anything.
        case selector

        var attributeName: String? {
            if case let .attribute(name) = self { return name }
            return nil
        }
    }

    let source: SourceText
    private(set) var declarations: [TerraformCodeMapDeclaration] = []
    private(set) var references: [TerraformCodeMapReference] = []
    /// IDs of parenthesized expressions an enclosing traversal already read through. Reading one
    /// again would repeat the rest of that traversal, which makes nested parentheses quadratic.
    private var readParentheses: Set<UInt> = []
    /// How many active scopes bind each name. Scopes enter and exit through the walk's stack, so
    /// each binder costs one update on entry and one on exit, and a nested binder that reuses a
    /// name doesn't end the outer binding.
    private var bindingCounts: [String: Int] = [:]

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
                // A `terraform` block configures Terraform itself: its provider and backend settings
                // never name a declaration.
                let readsReferences = blockType != "terraform"
                for item in TerraformCodeMapStrategy.syntaxChildren(of: child) {
                    try requirePresent(item)
                    switch item.nodeType {
                    case "attribute":
                        let attribute = try readAttribute(item)
                        attributes.append(attribute)
                        subtrees.append(.root(
                            attribute.expression,
                            reading: readsReferences
                                ? TerraformCodeMapStrategy.referenceReading(
                                    blockType: blockType ?? "",
                                    parentBlockType: nil,
                                    attributeName: attribute.name
                                )
                                : .skipped
                        ))
                    case "block":
                        // Always read the header: a source block must not skip validating later nested blocks.
                        let nestedName = try nestedBlockName(item)
                        hasSourceBlock = hasSourceBlock || nestedName == "source"
                        subtrees.append(.root(
                            item,
                            reading: readsReferences ? .expressions : .skipped,
                            parentBlockType: blockType
                        ))
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
        try visit([.root(readAttribute(attribute).expression, reading: .skipped)])
    }

    /// Visits every node below the given subtrees once with an explicit stack, so nesting depth in
    /// the source never deepens the call stack.
    private mutating func visit(_ subtrees: [Frame]) throws {
        var stack = subtrees.map(StackEntry.frame)
        while let entry = stack.popLast() {
            let frame: Frame
            switch entry {
            case let .frame(next):
                frame = next
            case let .enterScope(names):
                for name in names {
                    bindingCounts[name, default: 0] += 1
                }
                continue
            case let .exitScope(names):
                for name in names {
                    if let count = bindingCounts[name], count > 1 {
                        bindingCounts[name] = count - 1
                    } else {
                        bindingCounts[name] = nil
                    }
                }
                continue
            }
            let node = frame.node
            try requirePresent(node)
            let nodeType = node.nodeType
            if nodeType == "template_literal", frame.inQuotedTemplate {
                // HCL rejects an invalid escape in any quoted string, including values the outline omits.
                _ = try SourceText.decodedQuotedText(source.text(of: node))
            }
            let children = TerraformCodeMapStrategy.syntaxChildren(of: node)
            let wasReadThrough = readParentheses.remove(node.id) != nil
            if frame.reading != .skipped, !wasReadThrough {
                try collectReferences(among: children, reading: frame.reading)
            }
            let childrenInQuotedTemplate = switch nodeType {
            case "string_lit", "quoted_template": true
            case "heredoc_template": false
            default: frame.inQuotedTemplate
            }
            let childEntries: [StackEntry] = switch nodeType {
            case "block":
                try nestedBlockEntries(children, of: frame)
            case "for_tuple_expr", "for_object_expr":
                try scopedEntries(
                    children,
                    introType: "for_intro",
                    of: frame,
                    inQuotedTemplate: childrenInQuotedTemplate
                )
            case "template_for":
                try scopedEntries(
                    children,
                    introType: "template_for_start",
                    of: frame,
                    inQuotedTemplate: childrenInQuotedTemplate
                )
            default:
                children.map { .frame(frame.child($0, inQuotedTemplate: childrenInQuotedTemplate)) }
            }
            stack.append(contentsOf: childEntries.reversed())
        }
    }

    /// Stack entries for a nested block's labels and body. A `dynamic` block binds its iterator,
    /// named by `iterator` or else by its label, around `labels` and `content` but not `for_each`.
    private func nestedBlockEntries(_ children: [Node], of frame: Frame) throws -> [StackEntry] {
        guard let typeNode = children.first, typeNode.nodeType == "identifier" else {
            throw TerraformCodeMapSyntaxError(reason: "block without a type")
        }
        let blockType = source.text(of: typeNode)
        var unscoped: [Frame] = []
        var firstLabel: Node?
        var items: [Node] = []
        for child in children.dropFirst() {
            switch child.nodeType {
            case "string_lit", "identifier":
                firstLabel = firstLabel ?? child
                unscoped.append(frame.child(child, inQuotedTemplate: false))
            case "body":
                items = TerraformCodeMapStrategy.syntaxChildren(of: child)
            default:
                continue
            }
        }

        var attributes: [Attribute] = []
        var blocks: [Node] = []
        for item in items {
            try requirePresent(item)
            switch item.nodeType {
            case "attribute": try attributes.append(readAttribute(item))
            case "block": blocks.append(item)
            default: throw TerraformCodeMapSyntaxError(reason: "unexpected block body item")
            }
        }

        var iterator: [String] = []
        if blockType == "dynamic" {
            if let name = attributes.first(where: { $0.name == "iterator" }).flatMap({ bareIdentifier($0) }) {
                iterator = [name]
            } else if let firstLabel {
                iterator = try [firstLabel.nodeType == "string_lit"
                    ? source.decodedStringLiteral(firstLabel)
                    : source.text(of: firstLabel)]
            }
        }
        var scoped: [Frame] = []
        for attribute in attributes {
            let attributeFrame = frame.child(
                attribute.expression,
                inQuotedTemplate: false,
                reading: TerraformCodeMapStrategy.referenceReading(
                    blockType: blockType,
                    parentBlockType: frame.parentBlockType,
                    attributeName: attribute.name
                )
            )
            if attribute.name == "for_each" {
                unscoped.append(attributeFrame)
            } else {
                scoped.append(attributeFrame)
            }
        }
        scoped += blocks.map { frame.child($0, inQuotedTemplate: false, parentBlockType: blockType) }
        return unscoped.map(StackEntry.frame) + StackEntry.scope(iterator, around: scoped)
    }

    /// Stack entries for a `for` expression or template `for`. The intro's identifiers bind around
    /// the body, filter, and template contents; its collection expression stays outside that scope,
    /// and the identifiers are declarations, not references.
    private func scopedEntries(
        _ children: [Node],
        introType: String,
        of frame: Frame,
        inQuotedTemplate: Bool
    ) throws -> [StackEntry] {
        guard let intro = children.first(where: { $0.nodeType == introType }) else {
            throw TerraformCodeMapSyntaxError(reason: "for expression without an intro")
        }
        try requirePresent(intro)
        let introParts = TerraformCodeMapStrategy.syntaxChildren(of: intro)
        let bound = introParts.filter { $0.nodeType == "identifier" }.map(source.text(of:))
        let collection = introParts.filter { $0.nodeType == "expression" }.map {
            StackEntry.frame(frame.child($0, inQuotedTemplate: inQuotedTemplate))
        }
        let scoped = children.filter { $0.nodeType != introType }.map {
            frame.child($0, inQuotedTemplate: inQuotedTemplate)
        }
        return collection + StackEntry.scope(bound, around: scoped)
    }

    /// Reads every traversal among one node's children. The grammar puts a traversal's steps beside
    /// its base rather than inside it, and an operator's operands have no `expression` wrapper, so
    /// the steps are the base's following siblings up to the first node of another kind. Index
    /// expressions inside the steps are visited as their own subtrees. A root an enclosing scope
    /// binds names a local value, not a declaration.
    private mutating func collectReferences(among children: [Node], reading: ReferenceReading) throws {
        for offset in children.indices {
            guard let traversal = traversal(at: offset, in: children), bindingCounts[traversal.root] == nil else {
                continue
            }
            try references += Self.references(root: traversal.root, steps: traversal.steps, reading: reading)
        }
    }

    /// The traversal whose base is `children[offset]`, or nil when that node isn't a base. A base
    /// is a `variable_expr`, or a parenthesized expression whose content is exactly one traversal:
    /// parentheses don't change the object a traversal names, so the steps after them continue the
    /// inner traversal. Other content, such as a function call, keeps its result opaque. A loop
    /// reads nested parentheses, so their depth never deepens the call stack, and each
    /// parenthesized expression it reads through is recorded so `visit` doesn't read it again.
    private mutating func traversal(at offset: Int, in children: [Node]) -> (root: String, steps: [TraversalStep])? {
        var level = children
        var baseOffset = offset
        var stepsByLevel: [[TraversalStep]] = []
        var readThrough: [UInt] = []
        defer { readParentheses.formUnion(readThrough) }
        while level.indices.contains(baseOffset) {
            let base = level[baseOffset]
            let isParenthesized = base.nodeType == "expression" && baseOffset > 0 && baseOffset + 1 < level.count
                && level[baseOffset - 1].nodeType == "(" && level[baseOffset + 1].nodeType == ")"
            guard base.nodeType == "variable_expr" || isParenthesized else { return nil }
            var steps: [TraversalStep] = []
            for postfix in level[(baseOffset + (isParenthesized ? 2 : 1))...] {
                guard let postfixSteps = traversalSteps(of: postfix) else {
                    // Inside parentheses, anything after the traversal makes the content something
                    // else. The expression holding this level reads it as its own outer level,
                    // where trailing nodes are allowed, so that one isn't read through.
                    guard stepsByLevel.isEmpty else {
                        readThrough.removeLast()
                        return nil
                    }
                    break
                }
                steps += postfixSteps
            }
            stepsByLevel.append(steps)
            guard isParenthesized else {
                guard let name = TerraformCodeMapStrategy.syntaxChildren(of: base).first else { return nil }
                return (source.text(of: name), stepsByLevel.reversed().flatMap { $0 })
            }
            readThrough.append(base.id)
            level = TerraformCodeMapStrategy.syntaxChildren(of: base)
            baseOffset = level.first?.nodeType == "(" ? 1 : 0
        }
        return nil
    }

    /// The steps one postfix node adds, or nil when the node isn't a traversal step.
    private func traversalSteps(of node: Node) -> [TraversalStep]? {
        switch node.nodeType {
        case "get_attr":
            let name = TerraformCodeMapStrategy.syntaxChildren(of: node).first { $0.nodeType == "identifier" }
            return name.map { [.attribute(source.text(of: $0))] } ?? []
        case "index":
            return [.selector]
        case "splat":
            // The steps after a splat sit inside its `attr_splat` or `full_splat` child.
            let inner = TerraformCodeMapStrategy.syntaxChildren(of: node).flatMap {
                TerraformCodeMapStrategy.syntaxChildren(of: $0)
            }
            return [.selector] + inner.flatMap { traversalSteps(of: $0) ?? [] }
        default:
            return nil
        }
    }

    /// The declaration-level references one traversal makes. An instance selector after a module
    /// call doesn't change which output an attribute names, but a call followed by a selector and
    /// no attribute names only the call, because the selector could be an instance key or an
    /// output name. In an address, a call names only the call. A removed object's address names
    /// only a call it continues past, because a whole call it names is gone too.
    private static func references(
        root: String,
        steps: [TraversalStep],
        reading: ReferenceReading
    ) throws -> [TerraformCodeMapReference] {
        guard !TerraformCodeMapStrategy.nonDeclarationRoots.contains(root),
              let first = steps.first?.attributeName
        else {
            return []
        }
        // A removed object's address names only a module call, so no other root counts.
        if reading == .removedAddress, root != "module" { return [] }

        switch root {
        case "var":
            return try [TerraformCodeMapReference(kind: .variable, parts: [first])]
        case "local":
            return try [TerraformCodeMapReference(kind: .local, parts: [first])]
        case "data", "resource":
            // `resource.type.name` is the explicit form of `type.name`.
            guard let name = steps.dropFirst().first?.attributeName else { return [] }
            return try [TerraformCodeMapReference(kind: root == "data" ? .data : .resource, parts: [first, name])]
        case "module":
            // A removed call that nothing continues past is gone too, so it names no reference.
            if reading == .removedAddress, !steps.dropFirst().contains(where: { $0.attributeName != nil }) {
                return []
            }
            let moduleCall = try TerraformCodeMapReference(kind: .moduleCall, parts: [first])
            guard reading != .address, reading != .removedAddress else { return [moduleCall] }
            var afterCall = steps.dropFirst()
            if case .selector = afterCall.first {
                afterCall = afterCall.dropFirst()
            }
            guard let output = afterCall.first?.attributeName else { return [moduleCall] }
            return try [moduleCall, TerraformCodeMapReference(kind: .moduleOutput, parts: [first, output])]
        default:
            return try [TerraformCodeMapReference(kind: .resource, parts: [root, first])]
        }
    }

    /// The name in an expression that is exactly one identifier, such as a dynamic block's `iterator`.
    private func bareIdentifier(_ attribute: Attribute) -> String? {
        let terms = TerraformCodeMapStrategy.syntaxChildren(of: attribute.expression)
        guard terms.count == 1, terms[0].nodeType == "variable_expr",
              let name = TerraformCodeMapStrategy.syntaxChildren(of: terms[0]).first
        else {
            return nil
        }
        return source.text(of: name)
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
