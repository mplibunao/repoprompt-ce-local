import Foundation
import RepoPromptCodeMapCore

/// A Terraform module call in the graph: the loaded-root-relative folder that declares it, which is
/// empty for the loaded root, and the call's label.
struct TerraformCallKey: Hashable {
    let folder: String
    let call: String

    /// Stores the folder in NFC, as the posting keys do. String equality treats canonically equivalent
    /// spellings of a path as one folder, so an unnormalized key would keep whichever spelling the
    /// index saw first, and its byte accounting would differ from a rebuild's. The label comes from a
    /// canonical `tf1` tuple, whose components are already NFC.
    init(folder: String, call: String) {
        var normalizedFolder = folder.precomposedStringWithCanonicalMapping
        normalizedFolder.makeContiguousUTF8()
        self.folder = normalizedFolder
        self.call = call
    }
}

/// One file's declaration of a module call. The enclosing indexes supply the rest: the
/// `TerraformCallKey` holds its folder and label, and the declaring file's ID keys the binding
/// within its call.
struct TerraformCallBinding: Hashable {
    let source: TerraformModuleSource
    /// The file declares more than one `module` block with this label.
    let isDuplicated: Bool
}

/// A Terraform reference qualified by folder: the posting key it resolves against, and the text that
/// edge evidence and unresolved records show for it.
struct WorkspaceCodemapGraphProjectedReference: Hashable {
    /// `nil` when the reference reads a module call that no file in its folder declares. It then
    /// resolves like a name that nothing defines.
    let key: String?
    let evidence: String
}

/// The folder-qualified graph facts of one Terraform node. They come from its raw contribution, its
/// path, and the call bindings of the snapshot that holds it.
struct WorkspaceCodemapGraphNodeProjection: Hashable {
    /// Posting keys the file defines, unique and sorted by their UTF-8 bytes.
    let definitionKeys: [String]
    /// In the order of the raw references they come from.
    let references: [WorkspaceCodemapGraphProjectedReference]
    /// The calls whose bindings choose the targets of the file's child references, in the order the
    /// references first name them.
    let callDependencyKeys: [TerraformCallKey]
    /// Child references withheld because their call's binding doesn't name a child folder.
    let unresolved: [WorkspaceCodemapGraphUnresolvedRecord]

    /// The distinct posting keys the file's references resolve against, unordered.
    var referenceKeys: [String] {
        Array(Set(references.compactMap(\.key)))
    }
}
