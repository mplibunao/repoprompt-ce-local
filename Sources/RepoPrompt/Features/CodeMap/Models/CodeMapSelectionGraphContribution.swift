import CryptoKit
import Foundation
import RepoPromptCodeMapCore

struct CodeMapSelectionGraphContribution: Hashable {
    static let currentSchemaVersion: UInt32 = 1
    static let currentPolicyVersion: UInt32 = 2

    private static let digestDomain = "codemap-selection-graph-contribution-v1"

    let schemaVersion: UInt32
    let policyVersion: UInt32
    let artifactKey: CodeMapArtifactKey
    let sortedUniqueDefinitions: [String]
    let sortedUniqueReferences: [String]
    let contributionDigest: CodeMapSHA256Digest

    init(artifactKey: CodeMapArtifactKey, artifact: CodeMapSyntaxArtifact) {
        guard artifactKey.pipelineIdentity.languageID == .terraform else {
            self.init(
                artifactKey: artifactKey,
                definitions: artifact.definedTypeNames,
                references: artifact.referencedTypes
            )
            return
        }
        // The artifact container requires the payload on a ready Terraform artifact. Without it the
        // contribution has no folder membership, which graph-slot validation rejects.
        let names = artifact.terraform.map(TerraformCodeMapGraphNames.contributionNames)
        self.init(
            artifactKey: artifactKey,
            definitions: names?.definitions ?? [],
            references: names?.references ?? []
        )
    }

    init(
        artifactKey: CodeMapArtifactKey,
        definitions: some Sequence<String>,
        references: some Sequence<String>
    ) {
        // The Terraform codec normalizes each tuple component. Normalizing a whole token could
        // compose an escape's letter, such as the `n` of `\n`, with a combining mark that follows it.
        let normalizing = artifactKey.pipelineIdentity.languageID != .terraform
        let definitions = Self.canonicalNames(definitions, normalizing: normalizing)
        let references = Self.canonicalNames(references, normalizing: normalizing)

        schemaVersion = Self.currentSchemaVersion
        policyVersion = Self.currentPolicyVersion
        self.artifactKey = artifactKey
        sortedUniqueDefinitions = definitions
        sortedUniqueReferences = references
        contributionDigest = Self.digest(
            artifactKey: artifactKey,
            definitions: definitions,
            references: references
        )
    }

    /// Keeps each name's case, normalizes it to NFC when `normalizing`, drops names that are empty or
    /// start with U+0000, and deduplicates and sorts the rest by their UTF-8 bytes. This policy is
    /// independent of locale and input order. Empty names come from anonymous C enums and the
    /// manifest decoder rejects them. U+0000 starts the graph's Terraform posting keys, so no other
    /// name can equal one.
    private static func canonicalNames(_ names: some Sequence<String>, normalizing: Bool) -> [String] {
        let sorted = names.lazy
            .map { normalizing ? $0.precomposedStringWithCanonicalMapping : $0 }
            .filter { !$0.isEmpty && $0.utf8.first != 0 }
            .sorted { lhs, rhs in
                lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
            }
        // `String` equality is canonical equivalence, which would merge Terraform tokens whose bytes
        // differ and hide one of them from validation. For NFC names the two comparisons agree.
        var unique: [String] = []
        unique.reserveCapacity(sorted.count)
        for name in sorted where !(unique.last?.utf8.elementsEqual(name.utf8) ?? false) {
            unique.append(name)
        }
        return unique
    }

    private static func digest(
        artifactKey: CodeMapArtifactKey,
        definitions: [String],
        references: [String]
    ) -> CodeMapSHA256Digest {
        var writer = CodeMapSelectionGraphContributionCanonicalWriter()
        writer.appendString(digestDomain)
        writer.append(currentSchemaVersion)
        writer.append(currentPolicyVersion)
        writer.appendData(artifactKey.canonicalBytes)
        writer.appendStrings(definitions)
        writer.appendStrings(references)
        return try! CodeMapSHA256Digest(bytes: Data(SHA256.hash(data: writer.data)))
    }
}

private struct CodeMapSelectionGraphContributionCanonicalWriter {
    private(set) var data = Data()

    mutating func appendStrings(_ values: [String]) {
        precondition(values.count <= Int(UInt32.max))
        append(UInt32(values.count))
        for value in values {
            appendString(value)
        }
    }

    mutating func appendString(_ value: String) {
        appendData(Data(value.utf8))
    }

    mutating func appendData(_ value: Data) {
        precondition(value.count <= Int(UInt32.max))
        append(UInt32(value.count))
        data.append(value)
    }

    mutating func append(_ value: UInt32) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }
}
