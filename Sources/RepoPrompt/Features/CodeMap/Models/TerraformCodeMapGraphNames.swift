import Foundation
import RepoPromptCodeMapCore

/// The only codec for Terraform graph-contribution names. A name is `tf1:` followed by a compact
/// JSON array of strings in NFC, whose first element is the tuple's tag. A name contains only facts
/// from the file's source, never its folder or a resolved module destination. The graph qualifies
/// names by folder when it builds a snapshot.
///
/// A name decodes only when its tag and arity are known and encoding its components again gives the
/// same bytes. Whitespace, optional escapes, and components that aren't NFC fail that second check.
enum TerraformCodeMapGraphNames {
    /// A fact that a Terraform file defines.
    enum Definition: Hashable {
        /// The file belongs to its folder. Every ready Terraform artifact defines it, even an empty one.
        case folder
        case variable(name: String)
        case output(name: String)
        case local(name: String)
        case resource(type: String, name: String)
        case data(type: String, name: String)
        /// The file's first `module` block with this label.
        case call(name: String, source: TerraformModuleSource)
        /// The file has more than one `module` block with this label.
        case callDuplicate(name: String)
    }

    /// A fact that a Terraform file refers to.
    enum Reference: Hashable {
        case variable(name: String)
        case local(name: String)
        case resource(type: String, name: String)
        case data(type: String, name: String)
        case call(name: String)
        /// The folder a module call's source names. Every `module` block refers to it.
        case childFolder(call: String)
        /// A `module` block argument, which sets a `variable` in the child folder.
        case childInput(call: String, argument: String)
        /// A `module.<call>.<output>` expression, which reads an `output` in the child folder.
        case childOutput(call: String, output: String)
    }

    private static let prefix = "tf1:"

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        // The artifact container's canonical JSON settings.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static let decoder = JSONDecoder()

    /// The raw contribution names of one Terraform file: a `call` per module label from its first
    /// declaration, `call-duplicate` when the label repeats, and folder membership even when the
    /// file declares nothing.
    static func contributionNames(
        for artifact: TerraformCodeMapArtifact
    ) -> (definitions: [String], references: [String]) {
        var definitions: [Definition] = [.folder]
        var references: [Reference] = []
        // `String` equality is canonical equivalence, so labels that differ only in normalization,
        // which encode to the same tuple, count as repeats.
        var callNames = Set<String>()
        for declaration in artifact.declarations {
            // Terraform rejects an empty variable, output, module call, or resource or data type or
            // name as an invalid name, so skipping these declarations drops no link from a valid
            // configuration. The outline still shows them.
            guard !declaration.labels.contains(where: \.isEmpty) else { continue }
            let labels = declaration.labels
            switch declaration.kind {
            case .variable:
                definitions.append(.variable(name: labels[0]))
            case .output:
                definitions.append(.output(name: labels[0]))
            case .local:
                definitions.append(.local(name: labels[0]))
            case .resource:
                definitions.append(.resource(type: labels[0], name: labels[1]))
            case .data:
                definitions.append(.data(type: labels[0], name: labels[1]))
            case .module:
                // The declaration model requires a source on every module call.
                guard let source = declaration.moduleSource else { continue }
                let call = labels[0]
                definitions.append(
                    callNames.insert(call).inserted ? .call(name: call, source: source) : .callDuplicate(name: call)
                )
                references.append(.childFolder(call: call))
                references += declaration.argumentNames.map { .childInput(call: call, argument: $0) }
            case .other:
                continue
            }
        }
        for reference in artifact.references {
            let parts = reference.parts
            switch reference.kind {
            case .variable:
                references.append(.variable(name: parts[0]))
            case .local:
                references.append(.local(name: parts[0]))
            case .resource:
                references.append(.resource(type: parts[0], name: parts[1]))
            case .data:
                references.append(.data(type: parts[0], name: parts[1]))
            case .moduleCall:
                references.append(.call(name: parts[0]))
            case .moduleOutput:
                references.append(.call(name: parts[0]))
                references.append(.childOutput(call: parts[0], output: parts[1]))
            }
        }
        return (definitions.map(\.encoded), references.map(\.encoded))
    }

    /// Whether the names, byte for byte, form a contribution this codec produces: every name
    /// decodes as its side's tuple, folder membership is present, each module label has one `call`,
    /// and every `call-duplicate` repeats a label that has one.
    static func isValidContribution(definitions: [String], references: [String]) -> Bool {
        var hasFolder = false
        var callNames = Set<String>()
        var duplicateCallNames: [String] = []
        for name in definitions {
            guard let definition = Definition(encoded: name) else { return false }
            switch definition {
            case .folder:
                hasFolder = true
            case let .call(callName, _):
                guard callNames.insert(callName).inserted else { return false }
            case let .callDuplicate(callName):
                duplicateCallNames.append(callName)
            case .variable, .output, .local, .resource, .data:
                break
            }
        }
        return hasFolder &&
            duplicateCallNames.allSatisfy(callNames.contains) &&
            references.allSatisfy { Reference(encoded: $0) != nil }
    }

    fileprivate static func encode(_ components: [String]) -> String {
        let normalized = components.map(\.precomposedStringWithCanonicalMapping)
        // An array of strings always encodes.
        let json = try! encoder.encode(normalized)
        return prefix + String(decoding: json, as: UTF8.self)
    }

    /// The components of `name` when encoding them gives exactly `name`'s bytes.
    fileprivate static func components(of name: String) -> [String]? {
        let prefixByteCount = prefix.utf8.count
        guard name.utf8.starts(with: prefix.utf8),
              let components = try? decoder.decode([String].self, from: Data(name.utf8.dropFirst(prefixByteCount))),
              encode(components).utf8.elementsEqual(name.utf8)
        else { return nil }
        return components
    }

    /// The tuple's fields after its tag, when there are `count` of them and none is empty.
    fileprivate static func names(_ components: [String], count: Int) -> [String]? {
        let names = Array(components.dropFirst())
        guard names.count == count, names.allSatisfy({ !$0.isEmpty }) else { return nil }
        return names
    }
}

extension TerraformCodeMapGraphNames.Definition {
    private enum Tag: String {
        case folder
        case variable
        case output
        case local
        case resource
        case data
        case call
        case callDuplicate = "call-duplicate"
    }

    init?(encoded name: String) {
        guard let components = TerraformCodeMapGraphNames.components(of: name),
              let tag = components.first.flatMap(Tag.init(rawValue:))
        else { return nil }
        let fields = { TerraformCodeMapGraphNames.names(components, count: $0) }
        switch tag {
        case .folder:
            guard components.count == 1 else { return nil }
            self = .folder
        case .variable:
            guard let names = fields(1) else { return nil }
            self = .variable(name: names[0])
        case .output:
            guard let names = fields(1) else { return nil }
            self = .output(name: names[0])
        case .local:
            guard let names = fields(1) else { return nil }
            self = .local(name: names[0])
        case .resource:
            guard let names = fields(2) else { return nil }
            self = .resource(type: names[0], name: names[1])
        case .data:
            guard let names = fields(2) else { return nil }
            self = .data(type: names[0], name: names[1])
        case .call:
            // The label must be nonempty, but the source literal may be empty.
            guard components.count == 4, !components[1].isEmpty,
                  let source = Self.moduleSource(kind: components[2], literal: components[3])
            else { return nil }
            self = .call(name: components[1], source: source)
        case .callDuplicate:
            guard let names = fields(1) else { return nil }
            self = .callDuplicate(name: names[0])
        }
    }

    var encoded: String {
        let components: [String] = switch self {
        case .folder: [Tag.folder.rawValue]
        case let .variable(name): [Tag.variable.rawValue, name]
        case let .output(name): [Tag.output.rawValue, name]
        case let .local(name): [Tag.local.rawValue, name]
        case let .resource(type, name): [Tag.resource.rawValue, type, name]
        case let .data(type, name): [Tag.data.rawValue, type, name]
        case let .call(name, source): [Tag.call.rawValue, name, source.kind.rawValue, source.literalValue ?? ""]
        case let .callDuplicate(name): [Tag.callDuplicate.rawValue, name]
        }
        return TerraformCodeMapGraphNames.encode(components)
    }

    /// Only a literal source has a value, and an empty value still makes a literal.
    private static func moduleSource(kind: String, literal: String) -> TerraformModuleSource? {
        switch TerraformModuleSourceKind(rawValue: kind) {
        case .literal: .literal(literal)
        case .nonLiteral where literal.isEmpty: .nonLiteral
        case .missing where literal.isEmpty: .missing
        case .invalid where literal.isEmpty: .invalid
        case .nonLiteral, .missing, .invalid, nil: nil
        }
    }
}

extension TerraformCodeMapGraphNames.Reference {
    private enum Tag: String {
        case variable
        case local
        case resource
        case data
        case call
        case childFolder = "child-folder"
        case childInput = "child-input"
        case childOutput = "child-output"
    }

    init?(encoded name: String) {
        guard let components = TerraformCodeMapGraphNames.components(of: name),
              let tag = components.first.flatMap(Tag.init(rawValue:))
        else { return nil }
        let arity = switch tag {
        case .variable, .local, .call, .childFolder: 1
        case .resource, .data, .childInput, .childOutput: 2
        }
        guard let names = TerraformCodeMapGraphNames.names(components, count: arity) else { return nil }
        self = switch tag {
        case .variable: .variable(name: names[0])
        case .local: .local(name: names[0])
        case .resource: .resource(type: names[0], name: names[1])
        case .data: .data(type: names[0], name: names[1])
        case .call: .call(name: names[0])
        case .childFolder: .childFolder(call: names[0])
        case .childInput: .childInput(call: names[0], argument: names[1])
        case .childOutput: .childOutput(call: names[0], output: names[1])
        }
    }

    var encoded: String {
        let components: [String] = switch self {
        case let .variable(name): [Tag.variable.rawValue, name]
        case let .local(name): [Tag.local.rawValue, name]
        case let .resource(type, name): [Tag.resource.rawValue, type, name]
        case let .data(type, name): [Tag.data.rawValue, type, name]
        case let .call(name): [Tag.call.rawValue, name]
        case let .childFolder(call): [Tag.childFolder.rawValue, call]
        case let .childInput(call, argument): [Tag.childInput.rawValue, call, argument]
        case let .childOutput(call, output): [Tag.childOutput.rawValue, call, output]
        }
        return TerraformCodeMapGraphNames.encode(components)
    }
}
