import CryptoKit
import Foundation
@testable import RepoPromptApp
import RepoPromptCodeMapCore
import XCTest

final class TerraformCodemapPersistenceTests: XCTestCase {
    func testArtifactContributionMatchesVerifiedCleanRecordAndDecodedEnvelope() async throws {
        let cases: [(label: String, artifact: CodeMapSyntaxArtifact, definitions: [String], references: [String])] = try [
            (
                "declarations and references",
                makeArtifact(),
                [
                    #"tf1:["call","empty_source","literal",""]"#,
                    #"tf1:["call","remote","missing",""]"#,
                    #"tf1:["call","worker","literal","./modules/worker"]"#,
                    #"tf1:["call-duplicate","worker"]"#,
                    #"tf1:["data","example_zone","main"]"#,
                    #"tf1:["folder"]"#,
                    #"tf1:["local","name_prefix"]"#,
                    #"tf1:["output","endpoint"]"#,
                    #"tf1:["resource","example_bucket","primary"]"#,
                    "tf1:[\"variable\",\"caf\u{E9}\"]",
                    #"tf1:["variable","region"]"#
                ],
                [
                    #"tf1:["call","remote"]"#,
                    #"tf1:["call","worker"]"#,
                    #"tf1:["child-folder","empty_source"]"#,
                    #"tf1:["child-folder","remote"]"#,
                    #"tf1:["child-folder","worker"]"#,
                    #"tf1:["child-input","remote","region"]"#,
                    #"tf1:["child-input","worker","region"]"#,
                    #"tf1:["child-input","worker","replicas"]"#,
                    #"tf1:["child-input","worker","size"]"#,
                    #"tf1:["child-output","worker","endpoint"]"#,
                    #"tf1:["data","example_zone","main"]"#,
                    #"tf1:["local","name_prefix"]"#,
                    #"tf1:["resource","example_bucket","primary"]"#,
                    #"tf1:["variable","region"]"#
                ]
            ),
            ("empty file", makeArtifact(declarations: [], references: []), [#"tf1:["folder"]"#], []),
            (
                "escape before a combining mark",
                makeArtifact(
                    declarations: [
                        TerraformCodeMapDeclaration(
                            kind: .module,
                            blockType: "module",
                            labels: ["newline"],
                            lineNumber: 1,
                            moduleSource: .literal("\n\u{303}")
                        ),
                        TerraformCodeMapDeclaration(
                            kind: .module,
                            blockType: "module",
                            labels: ["return"],
                            lineNumber: 4,
                            moduleSource: .literal("\r\u{301}")
                        )
                    ],
                    references: []
                ),
                [
                    "tf1:[\"call\",\"newline\",\"literal\",\"\\n\u{303}\"]",
                    "tf1:[\"call\",\"return\",\"literal\",\"\\r\u{301}\"]",
                    #"tf1:["folder"]"#
                ],
                [#"tf1:["child-folder","newline"]"#, #"tf1:["child-folder","return"]"#]
            )
        ]
        let fixture = try makeFixture()

        for (index, testCase) in cases.enumerated() {
            let association = try await fixture.store(testCase.artifact, seed: UInt8(index + 1))
            let key = association.artifactKey

            // Artifact construction, through the initializer the binding engine, the manifest writer,
            // and the live overlay call.
            let built = CodeMapSelectionGraphContribution(artifactKey: key, artifact: testCase.artifact)
            assertSameBytes(built.sortedUniqueDefinitions, testCase.definitions, testCase.label)
            assertSameBytes(built.sortedUniqueReferences, testCase.references, testCase.label)

            // `verifiedClean` derives its own contribution from the artifact as decoded from the store
            // and accepts only an equal one.
            let record = try fixture.verifiedCleanRecord(association: association, contribution: built)

            // The decoded envelope, from which a manifest load rebuilds the contribution.
            let decoded = try XCTUnwrap(fixture.decode(fixture.encode(record)).records.first, testCase.label)
            let envelope = try XCTUnwrap(decoded.contributionEnvelope, testCase.label)
            let reloaded = CodeMapSelectionGraphContribution(
                artifactKey: decoded.artifactKey,
                definitions: envelope.sortedUniqueDefinitions,
                references: envelope.sortedUniqueReferences
            )
            XCTAssertEqual(decoded.contribution, CodeMapRootManifestContributionIdentity(built), testCase.label)
            assertSameBytes(reloaded.sortedUniqueDefinitions, built.sortedUniqueDefinitions, testCase.label)
            assertSameBytes(reloaded.sortedUniqueReferences, built.sortedUniqueReferences, testCase.label)
            XCTAssertEqual(reloaded.contributionDigest, built.contributionDigest, testCase.label)
        }
    }

    func testCanonicalTokensRejectMalformedOrUnexpectedShapes() async throws {
        let definitions = [
            #"tf1:["call","worker","literal","./modules/worker"]"#,
            #"tf1:["call-duplicate","worker"]"#,
            #"tf1:["folder"]"#
        ]
        let references = [#"tf1:["child-input","worker","region"]"#]
        XCTAssertTrue(TerraformCodeMapGraphNames.isValidContribution(definitions: definitions, references: references))

        let malformedDefinitions = [
            ("plain legacy name", "Value"),
            ("no prefix", #"["output","endpoint"]"#),
            ("another version's prefix", #"tf2:["output","endpoint"]"#),
            ("unknown tag", #"tf1:["module","worker"]"#),
            ("folder-qualified tuple", #"tf1:["modules/worker","variable","region"]"#),
            ("reference tag", #"tf1:["child-folder","worker"]"#),
            ("folder with a component", #"tf1:["folder","modules/worker"]"#),
            ("variable without a name", #"tf1:["variable"]"#),
            ("resource with one label", #"tf1:["resource","example_bucket"]"#),
            ("empty name", #"tf1:["output",""]"#),
            ("call without its source", #"tf1:["call","other"]"#),
            ("unknown source kind", #"tf1:["call","other","registry",""]"#),
            ("non-literal source with a value", #"tf1:["call","other","nonLiteral","./x"]"#),
            ("decomposed name", "tf1:[\"output\",\"cafe\u{301}\"]"),
            ("whitespace", #"tf1:["output", "endpoint"]"#),
            ("escaped slash", #"tf1:["call","other","literal",".\/x"]"#),
            ("escaped letter", #"tf1:["output","\u0065ndpoint"]"#),
            ("component that isn't a string", #"tf1:["output",1]"#),
            ("trailing bytes", #"tf1:["output","endpoint"]x"#)
        ]
        for (label, name) in malformedDefinitions {
            XCTAssertFalse(
                TerraformCodeMapGraphNames.isValidContribution(definitions: definitions + [name], references: references),
                label
            )
        }

        let malformedReferences = [
            ("definition tag", #"tf1:["output","endpoint"]"#),
            ("folder", #"tf1:["folder"]"#),
            ("call with its source", #"tf1:["call","worker","literal","./modules/worker"]"#),
            ("child input without its argument", #"tf1:["child-input","worker"]"#),
            ("child output with an extra component", #"tf1:["child-output","worker","endpoint","port"]"#),
            ("empty argument", #"tf1:["child-input","worker",""]"#)
        ]
        for (label, name) in malformedReferences {
            XCTAssertFalse(
                TerraformCodeMapGraphNames.isValidContribution(definitions: definitions, references: references + [name]),
                label
            )
        }

        let inconsistentDefinitions = [
            ("no folder membership", Array(definitions.dropLast())),
            ("two calls for one label", definitions + [#"tf1:["call","worker","missing",""]"#]),
            ("repeat of a label without a call", [#"tf1:["call-duplicate","other"]"#, #"tf1:["folder"]"#])
        ]
        for (label, names) in inconsistentDefinitions {
            XCTAssertFalse(
                TerraformCodeMapGraphNames.isValidContribution(definitions: names, references: references),
                label
            )
        }

        // The graph slot rejects names that aren't Terraform tuples, and a Terraform file without
        // folder membership.
        let fixture = try makeFixture()
        let key = CodeMapArtifactKey(
            rawSHA256: CodeMapRawSourceDigest(bytes: Data(repeating: 9, count: 32)),
            rawByteCount: 9,
            pipelineIdentity: fixture.namespace.pipelineIdentity
        )
        // Whole-token NFC composes the escape's `n` with the combining mark into an invalid escape.
        let escapedLiteral = "tf1:[\"call\",\"newline\",\"literal\",\"\\n\u{303}\"]"
        let slotStates: [(String, WorkspaceCodemapGraphSlotState)] = [
            ("legacy name", .contributed(CodeMapSelectionGraphContribution(
                artifactKey: key,
                definitions: definitions + ["Value"],
                references: references
            ))),
            ("no names", .empty(CodeMapSelectionGraphContribution(artifactKey: key, definitions: [], references: []))),
            ("valid token beside its canonically equivalent twin", .contributed(CodeMapSelectionGraphContribution(
                artifactKey: key,
                definitions: definitions + [escapedLiteral, escapedLiteral.precomposedStringWithCanonicalMapping],
                references: references
            )))
        ]
        for (label, state) in slotStates {
            XCTAssertEqual(try fixture.slot(state), .failure(.invalidTerraformContribution), label)
        }
        let valid = CodeMapSelectionGraphContribution(artifactKey: key, definitions: definitions, references: references)
        XCTAssertNoThrow(try fixture.slot(.contributed(valid)).get())

        // A record whose digest covers a tuple that isn't NFC, as a faulty writer could persist, passes
        // the identity check. The decoder's tuple check must reject it.
        let association = try await fixture.store(
            makeArtifact(
                declarations: [TerraformCodeMapDeclaration(
                    kind: .variable,
                    blockType: "variable",
                    labels: ["caf\u{E9}"],
                    lineNumber: 1
                )],
                references: []
            ),
            seed: 10
        )
        let record = try fixture.verifiedCleanRecord(
            association: association,
            contribution: CodeMapSelectionGraphContribution(
                artifactKey: association.artifactKey,
                artifact: XCTUnwrap(association.outcome.readyArtifact)
            )
        )
        let decomposedName = "tf1:[\"variable\",\"cafe\u{301}\"]"
        let resigned = CodeMapSelectionGraphContribution(
            artifactKey: association.artifactKey,
            definitions: [#"tf1:["folder"]"#, decomposedName],
            references: []
        )
        let decomposed = try resealedManifest(fixture.encode(record), replacing: [
            (lengthPrefixed("tf1:[\"variable\",\"caf\u{E9}\"]"), lengthPrefixed(decomposedName)),
            (XCTUnwrap(record.contribution).digest.bytes, resigned.contributionDigest.bytes)
        ])
        XCTAssertThrowsError(try fixture.decode(decomposed)) { error in
            XCTAssertEqual(error as? CodeMapRootManifestDecodeFailure, .contributionValidation)
        }

        // A legacy name can't take the U+0000 prefix of the graph's Terraform posting keys.
        let legacy = try CodeMapSelectionGraphContribution(
            artifactKey: CodeMapArtifactKey(
                rawSHA256: CodeMapRawSourceDigest(bytes: Data(repeating: 11, count: 32)),
                rawByteCount: 11,
                pipelineIdentity: SyntaxManager().pipelineIdentity(for: .swift, decoderPolicy: .workspaceAutomaticV1)
            ),
            definitions: ["\u{0}" + #"tf1:["modules/worker","folder"]"#, "Value"],
            references: ["\u{0}Value"]
        )
        XCTAssertEqual(legacy.sortedUniqueDefinitions, ["Value"])
        XCTAssertEqual(legacy.sortedUniqueReferences, [])
    }

    // MARK: - Fixtures

    private struct Fixture {
        let artifacts: CodeMapArtifactStore
        let namespace: CodeMapRootManifestNamespace
        let authority: CodeMapRootManifestAuthority

        /// Stores `artifact` under a Terraform key and returns the association a clean Git blob of it
        /// would have, whose outcome is the artifact as decoded from the store.
        func store(
            _ artifact: CodeMapSyntaxArtifact,
            seed: UInt8
        ) async throws -> VerifiedGitBlobCodeMapLocatorAssociation {
            let key = CodeMapArtifactKey(
                rawSHA256: CodeMapRawSourceDigest(bytes: Data(repeating: seed, count: 32)),
                rawByteCount: UInt64(seed),
                pipelineIdentity: namespace.pipelineIdentity
            )
            _ = try await artifacts.insert(key: key, deterministicOutcome: .ready(artifact))
            guard case let .hit(_, handle) = try await artifacts.lookup(key: key) else {
                throw CodeMapArtifactFileStoreError.integrityCollision
            }
            return try VerifiedGitBlobCodeMapLocatorAssociation.revalidatePersisted(
                identity: GitBlobCodeMapLocatorIdentity(
                    repositoryNamespace: namespace.repositoryNamespace,
                    objectFormat: .sha1,
                    blobOID: String(repeating: String(format: "%02x", seed), count: 20),
                    pipelineIdentity: namespace.pipelineIdentity
                ),
                artifactKey: key,
                casHandle: handle
            )
        }

        func verifiedCleanRecord(
            association: VerifiedGitBlobCodeMapLocatorAssociation,
            contribution: CodeMapSelectionGraphContribution
        ) throws -> CodeMapRootManifestRecord {
            try CodeMapRootManifestRecord.verifiedClean(
                namespace: namespace,
                repositoryRelativePath: "modules/worker/main.tf",
                gitMode: .regular,
                association: association,
                contribution: contribution,
                authority: authority,
                bindingGeneration: 1
            )
        }

        func encode(_ record: CodeMapRootManifestRecord) throws -> Data {
            try CodeMapRootManifestCodec.encode(snapshot: CodeMapRootManifestSnapshot(
                namespace: namespace,
                authority: authority,
                manifestGeneration: 1,
                lastAccessEpochSeconds: 100,
                records: [record]
            ))
        }

        func decode(_ data: Data) throws -> CodeMapRootManifestSnapshot {
            try CodeMapRootManifestCodec.decode(
                data,
                expectedNamespace: namespace,
                filenameDigest: namespace.storageDigestHex
            )
        }

        func slot(
            _ state: WorkspaceCodemapGraphSlotState
        ) throws -> Result<WorkspaceCodemapGraphSlot, WorkspaceCodemapGraphSlotValidationError> {
            let rootEpoch = try WorkspaceCodemapRootEpoch(
                rootID: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001")),
                rootLifetimeID: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
            )
            let identity = try XCTUnwrap(WorkspaceCodemapArtifactBindingIdentity(
                rootID: rootEpoch.rootID,
                rootLifetimeID: rootEpoch.rootLifetimeID,
                fileID: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000003")),
                standardizedRootPath: "/workspace",
                standardizedRelativePath: "modules/worker/main.tf",
                standardizedFullPath: "/workspace/modules/worker/main.tf"
            ))
            return WorkspaceCodemapGraphSlot.validated(
                rootEpoch: rootEpoch,
                identity: identity,
                requestGeneration: 1,
                pathGeneration: 1,
                pipelineIdentity: namespace.pipelineIdentity,
                state: state
            )
        }
    }

    private func makeFixture() throws -> Fixture {
        let root = try makeSecureRoot()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let pipeline = try SyntaxManager().pipelineIdentity(for: .terraform, decoderPolicy: .workspaceAutomaticV1)
        return try Fixture(
            artifacts: CodeMapArtifactStore(rootURL: root),
            namespace: CodeMapRootManifestNamespace(
                repositoryNamespace: GitBlobRepositoryNamespace(rawValue: String(repeating: "ab", count: 32)),
                worktreeIdentity: "wt_" + String(repeating: "a", count: 64),
                repositoryRelativeLoadedRootPrefix: "",
                objectFormat: .sha1,
                pipelineIdentity: pipeline,
                repositoryBindingEpoch: "repository",
                worktreeBindingEpoch: "worktree"
            ),
            authority: CodeMapRootManifestAuthority(
                authorityGeneration: 1, repositoryBindingEpoch: "repository", worktreeBindingEpoch: "worktree",
                layoutGeneration: "layout", indexGeneration: "index", checkoutConfigurationGeneration: "checkout",
                attributeGeneration: "attributes", sparseGeneration: "sparse", metadataGeneration: "metadata"
            )
        )
    }

    /// A module folder's file with every declaration and reference kind a contribution draws on, a
    /// repeated module label whose second declaration has another source, a label that isn't NFC, an
    /// empty label, and a provider block.
    private func makeArtifact() throws -> CodeMapSyntaxArtifact {
        try makeArtifact(
            declarations: [
                TerraformCodeMapDeclaration(kind: .variable, blockType: "variable", labels: ["region"], lineNumber: 1),
                TerraformCodeMapDeclaration(kind: .variable, blockType: "variable", labels: ["cafe\u{301}"], lineNumber: 2),
                TerraformCodeMapDeclaration(kind: .variable, blockType: "variable", labels: [""], lineNumber: 3),
                TerraformCodeMapDeclaration(kind: .output, blockType: "output", labels: ["endpoint"], lineNumber: 4),
                TerraformCodeMapDeclaration(kind: .local, blockType: "locals", labels: ["name_prefix"], lineNumber: 6),
                TerraformCodeMapDeclaration(
                    kind: .resource,
                    blockType: "resource",
                    labels: ["example_bucket", "primary"],
                    lineNumber: 8
                ),
                TerraformCodeMapDeclaration(kind: .data, blockType: "data", labels: ["example_zone", "main"], lineNumber: 10),
                TerraformCodeMapDeclaration(kind: .other, blockType: "provider", labels: ["example"], lineNumber: 12),
                TerraformCodeMapDeclaration(
                    kind: .module,
                    blockType: "module",
                    labels: ["worker"],
                    lineNumber: 14,
                    moduleSource: .literal("./modules/worker"),
                    argumentNames: ["size", "region"]
                ),
                TerraformCodeMapDeclaration(
                    kind: .module,
                    blockType: "module",
                    labels: ["worker"],
                    lineNumber: 18,
                    moduleSource: .nonLiteral,
                    argumentNames: ["replicas"]
                ),
                TerraformCodeMapDeclaration(
                    kind: .module,
                    blockType: "module",
                    labels: ["remote"],
                    lineNumber: 22,
                    moduleSource: .missing,
                    argumentNames: ["region"]
                ),
                TerraformCodeMapDeclaration(
                    kind: .module,
                    blockType: "module",
                    labels: ["empty_source"],
                    lineNumber: 25,
                    moduleSource: .literal("")
                )
            ],
            references: [
                TerraformCodeMapReference(kind: .variable, parts: ["region"]),
                TerraformCodeMapReference(kind: .local, parts: ["name_prefix"]),
                TerraformCodeMapReference(kind: .resource, parts: ["example_bucket", "primary"]),
                TerraformCodeMapReference(kind: .data, parts: ["example_zone", "main"]),
                TerraformCodeMapReference(kind: .moduleCall, parts: ["remote"]),
                TerraformCodeMapReference(kind: .moduleOutput, parts: ["worker", "endpoint"])
            ]
        )
    }

    private func makeArtifact(
        declarations: [TerraformCodeMapDeclaration],
        references: [TerraformCodeMapReference]
    ) -> CodeMapSyntaxArtifact {
        CodeMapSyntaxArtifact(
            imports: [],
            classes: [],
            functions: [],
            enums: [],
            globalVars: [],
            macros: [],
            referencedTypes: [],
            terraform: TerraformCodeMapArtifact(declarations: declarations, references: references)
        )
    }

    /// Replaces byte sequences in an encoded manifest and reseals its checksum.
    private func resealedManifest(_ manifest: Data, replacing replacements: [(Data, Data)]) throws -> Data {
        var payload = manifest.dropLast(SHA256.byteCount)
        for (old, new) in replacements {
            let range = try XCTUnwrap(payload.range(of: old))
            payload.replaceSubrange(range, with: new)
        }
        return Data(payload) + Data(SHA256.hash(data: payload))
    }

    /// A manifest string as the codec writes it: a big-endian UTF-8 byte count, then the bytes.
    private func lengthPrefixed(_ value: String) -> Data {
        let bytes = Data(value.utf8)
        return withUnsafeBytes(of: UInt32(bytes.count).bigEndian) { Data($0) } + bytes
    }

    /// Compares names by their UTF-8 bytes as well, because `String` equality ignores normalization.
    private func assertSameBytes(
        _ actual: [String],
        _ expected: [String],
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual, expected, message, file: file, line: line)
        XCTAssertEqual(actual.map { Array($0.utf8) }, expected.map { Array($0.utf8) }, message, file: file, line: line)
    }
}

private extension CodeMapSyntaxArtifactOutcome {
    var readyArtifact: CodeMapSyntaxArtifact? {
        if case let .ready(artifact) = self { return artifact }
        return nil
    }
}
