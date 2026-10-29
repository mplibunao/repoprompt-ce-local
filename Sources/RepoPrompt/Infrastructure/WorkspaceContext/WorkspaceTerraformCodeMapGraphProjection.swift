import Foundation
import RepoPromptCodeMapCore

/// Qualifies Terraform contributions by folder while the selection graph builds a candidate. Each
/// function is synchronous and reads only its arguments.
enum WorkspaceTerraformCodeMapGraphProjection {
    typealias Definition = TerraformCodeMapGraphNames.Definition
    typealias Reference = TerraformCodeMapGraphNames.Reference
    typealias Symbol = TerraformCodeMapGraphNames.Symbol

    /// A Terraform contribution's decoded tuples and the folder of the file that holds it.
    struct Facts {
        let folder: String
        let definitions: [Definition]
        let references: [Reference]
    }

    /// Where a module call's child references point.
    enum CallTarget: Hashable {
        /// No file in the caller's folder declares the call.
        case unbound
        /// The loaded-root-relative child folder, empty for the loaded root.
        case folder(String)
        case unresolved(WorkspaceCodemapGraphUnresolvedReason)
    }

    /// Nil for a contribution in any other language.
    static func facts(path: String, contribution: CodeMapSelectionGraphContribution) -> Facts? {
        guard contribution.artifactKey.pipelineIdentity.languageID == .terraform else { return nil }
        // Graph-slot validation admits only canonical tuples, so every name decodes.
        return Facts(
            folder: folder(ofRelativePath: path),
            definitions: contribution.sortedUniqueDefinitions.compactMap(Definition.init(encoded:)),
            references: contribution.sortedUniqueReferences.compactMap(Reference.init(encoded:))
        )
    }

    /// The folder of a standardized loaded-root-relative path, empty for a file in the loaded root.
    /// The search runs over UTF-8 bytes, because a slash followed by a combining mark is one
    /// `Character` and a character search would skip it.
    static func folder(ofRelativePath path: String) -> String {
        guard let slash = path.utf8.lastIndex(of: UInt8(ascii: "/")) else { return "" }
        return String(decoding: path.utf8[..<slash], as: UTF8.self)
    }

    /// The module calls the file declares.
    static func callBindings(facts: Facts) -> [TerraformCallKey: TerraformCallBinding] {
        var duplicatedCalls = Set<String>()
        for case let .callDuplicate(name) in facts.definitions {
            duplicatedCalls.insert(name)
        }
        var bindings: [TerraformCallKey: TerraformCallBinding] = [:]
        for case let .call(name, source) in facts.definitions {
            bindings[TerraformCallKey(folder: facts.folder, call: name)] = TerraformCallBinding(
                source: source,
                isDuplicated: duplicatedCalls.contains(name)
            )
        }
        return bindings
    }

    /// The calls whose bindings the file's child references go through.
    static func callDependencyKeys(facts: Facts) -> [TerraformCallKey] {
        var calls = Set<String>()
        var keys: [TerraformCallKey] = []
        for reference in facts.references {
            switch reference {
            case let .childFolder(call), let .childInput(call, _), let .childOutput(call, _):
                if calls.insert(call).inserted {
                    keys.append(TerraformCallKey(folder: facts.folder, call: call))
                }
            case .variable, .local, .resource, .data, .call:
                continue
            }
        }
        return keys
    }

    /// Interprets the declarations of one call. A label declared twice, in one file or in two, is
    /// ambiguous: choosing one would need Terraform's override-file merge, which this resolver
    /// doesn't reproduce.
    static func callTarget(
        key: TerraformCallKey,
        bindings: PersistentHashMap<UUID, TerraformCallBinding>?,
        candidateOverflowThreshold: UInt64
    ) -> CallTarget {
        guard let bindings, !bindings.isEmpty else { return .unbound }
        guard UInt64(bindings.count) <= candidateOverflowThreshold else { return .unresolved(.tooCommon) }
        var declarations = bindings.makeIterator()
        guard bindings.count == 1, let binding = declarations.next()?.value, !binding.isDuplicated else {
            return .unresolved(.ambiguousModuleCall)
        }
        return childFolder(callerFolder: key.folder, source: binding.source)
    }

    /// Resolves a module source lexically against the caller's folder. Nothing on disk is read, so
    /// symlinks aren't followed and the match is case-sensitive.
    static func childFolder(callerFolder: String, source: TerraformModuleSource) -> CallTarget {
        switch source {
        case .missing, .invalid:
            return .unresolved(.invalidModuleCall)
        case .nonLiteral:
            return .unresolved(.unsupportedModuleSource)
        case let .literal(literal):
            guard !literal.isEmpty, !StandardizedPath.containsNUL(literal) else {
                return .unresolved(.invalidModuleCall)
            }
            // Terraform reads only a source starting with `./` or `../` as a local path. Any other
            // source is a registry, Git, HTTP, or absolute address.
            guard literal.utf8.starts(with: "./".utf8) || literal.utf8.starts(with: "../".utf8) else {
                return .unresolved(.unsupportedModuleSource)
            }
            let folder = StandardizedPath.relative(callerFolder.isEmpty ? literal : callerFolder + "/" + literal)
            guard !WorkspaceCodemapArtifactBindingIdentity.escapesRoot(folder) else {
                return .unresolved(.outsideLoadedRoot)
            }
            return .folder(folder)
        }
    }

    /// Qualifies the file's tuples by its folder and points its child references at the folder its
    /// calls resolve to, as `bindings` declares them.
    static func projection(
        fileID: UUID,
        facts: Facts,
        candidateOverflowThreshold: UInt64,
        bindings: (TerraformCallKey) -> PersistentHashMap<UUID, TerraformCallBinding>?,
        comparisons: inout UInt64
    ) -> WorkspaceCodemapGraphNodeProjection {
        let folder = facts.folder
        var definitionKeys = Set<String>()
        for definition in facts.definitions {
            let symbol: Symbol? = switch definition {
            case .folder: .folder
            case let .variable(name): .variable(name: name)
            case let .output(name): .output(name: name)
            case let .local(name): .local(name: name)
            case let .resource(type, name): .resource(type: type, name: name)
            case let .data(type, name): .data(type: type, name: name)
            case let .call(name, _): .call(name: name)
            // The file's `call` tuple for the label already defines the call.
            case .callDuplicate: nil
            }
            if let symbol {
                definitionKeys.insert(TerraformCodeMapGraphNames.postingKey(folder: folder, symbol: symbol))
            }
        }

        var targetsByCall: [String: CallTarget] = [:]
        func target(of call: String) -> CallTarget {
            if let target = targetsByCall[call] { return target }
            let key = TerraformCallKey(folder: folder, call: call)
            let target = callTarget(
                key: key,
                bindings: bindings(key),
                candidateOverflowThreshold: candidateOverflowThreshold
            )
            targetsByCall[call] = target
            return target
        }

        var references: [WorkspaceCodemapGraphProjectedReference] = []
        var unresolved: [WorkspaceCodemapGraphUnresolvedRecord] = []
        func appendLocal(_ symbol: Symbol, kind: String, names: [String]) {
            references.append(WorkspaceCodemapGraphProjectedReference(
                key: TerraformCodeMapGraphNames.postingKey(folder: folder, symbol: symbol),
                evidence: "terraform " + address(folder: folder, kind: kind, names: names)
            ))
        }
        /// `role` names the child reference, and `childAddress` renders its target in the child folder.
        func appendChild(
            call: String,
            role: String,
            symbol: Symbol,
            childAddress: (String) -> String
        ) {
            let prefix = "terraform " + address(folder: folder, kind: "module", names: [call]) + " " + role
            switch target(of: call) {
            case .unbound:
                references.append(WorkspaceCodemapGraphProjectedReference(key: nil, evidence: prefix))
            case let .folder(child):
                references.append(WorkspaceCodemapGraphProjectedReference(
                    key: TerraformCodeMapGraphNames.postingKey(folder: child, symbol: symbol),
                    evidence: prefix + " -> " + childAddress(child)
                ))
            case let .unresolved(reason):
                unresolved.append(WorkspaceCodemapGraphUnresolvedRecord(
                    sourceFileID: fileID,
                    referencedName: prefix,
                    reason: reason
                ))
            }
        }

        for reference in facts.references {
            switch reference {
            case let .variable(name):
                appendLocal(.variable(name: name), kind: "var", names: [name])
            case let .local(name):
                appendLocal(.local(name: name), kind: "local", names: [name])
            case let .resource(type, name):
                appendLocal(.resource(type: type, name: name), kind: "resource", names: [type, name])
            case let .data(type, name):
                appendLocal(.data(type: type, name: name), kind: "data", names: [type, name])
            case let .call(name):
                appendLocal(.call(name: name), kind: "module", names: [name])
            case let .childFolder(call):
                appendChild(call: call, role: "source", symbol: .folder) { displayFolder($0) }
            case let .childInput(call, argument):
                appendChild(call: call, role: "input " + quoted(argument), symbol: .variable(name: argument)) {
                    address(folder: $0, kind: "var", names: [argument])
                }
            case let .childOutput(call, output):
                appendChild(call: call, role: "output " + quoted(output), symbol: .output(name: output)) {
                    address(folder: $0, kind: "output", names: [output])
                }
            }
        }

        return WorkspaceCodemapGraphNodeProjection(
            definitionKeys: definitionKeys.sorted {
                comparisons &+= 1
                return WorkspaceCodemapGraphOrdering.utf8Precedes($0, $1)
            },
            references: references,
            callDependencyKeys: callDependencyKeys(facts: facts),
            unresolved: unresolved
        )
    }

    /// `"<folder>"::<kind>."<name>"`, with one quoted component per name.
    private static func address(folder: String, kind: String, names: [String]) -> String {
        displayFolder(folder) + "::" + kind + names.map { "." + quoted($0) }.joined()
    }

    /// The loaded root displays as `"."`.
    private static func displayFolder(_ folder: String) -> String {
        quoted(folder.isEmpty ? "." : folder)
    }

    /// Escapes backslashes and quotes, so every rendered address reads back unambiguously.
    private static func quoted(_ component: String) -> String {
        let escaped = component
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"" + escaped + "\""
    }
}
