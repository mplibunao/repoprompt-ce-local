import CryptoKit
import Darwin
import Foundation
@testable import RepoPromptApp
import RepoPromptCodeMapCore
import XCTest

final class CodeMapArtifactContainerTests: XCTestCase {
    func testAllDeterministicOutcomesRoundTripThroughFixedContainer() throws {
        let key = try makeKey(sourceText: "all outcomes")
        let outcomes: [CodeMapSyntaxArtifactOutcome] = [
            .ready(makeArtifact()),
            .readyNoSymbols,
            .oversize(.utf8Bytes(actual: 20, limit: 10)),
            .oversize(.utf16Units(actual: 30, limit: 20)),
            .oversize(.lines(actual: 40, limit: 30)),
            .decodeFailed(.undecodable),
            .parseFailed(.parserReturnedNilTree),
            .parseFailed(.parserReturnedNilRoot)
        ]

        for outcome in outcomes {
            let encoded = try CodeMapArtifactContainer.encode(key: key, outcome: outcome)
            XCTAssertEqual(encoded.prefix(CodeMapArtifactContainer.magic.count), CodeMapArtifactContainer.magic)
            XCTAssertEqual(readUInt32(encoded, at: 16), CodeMapArtifactContainer.containerVersion)
            let decoded = try CodeMapArtifactContainer.decode(
                encoded,
                expectedKey: key,
                filenameDigest: key.storageDigestHex
            )
            XCTAssertEqual(decoded.key, key)
            XCTAssertEqual(decoded.outcome, outcome)
            XCTAssertEqual(decoded.containerByteCount, encoded.count)
            XCTAssertGreaterThan(decoded.payloadByteCount, 0)
            XCTAssertEqual(
                try CodeMapArtifactContainer.encode(key: decoded.key, outcome: decoded.outcome),
                encoded
            )
        }
    }

    func testStrictFramingRejectsKeySchemaKindLengthChecksumSummaryAndPayloadFaults() throws {
        let key = try makeKey(sourceText: "strict framing")
        let otherKey = try makeKey(sourceText: "other key")
        let canonical = try CodeMapArtifactContainer.encode(key: key, outcome: .ready(makeArtifact()))
        let layout = parseLayout(canonical)

        var wrongMagic = canonical
        wrongMagic[0] ^= 0xFF
        assertDecode(wrongMagic, key: key, throws: .invalidMagic)

        var wrongVersion = canonical
        replaceUInt32(&wrongVersion, at: 16, with: 2)
        assertDecode(wrongVersion, key: key, throws: .unsupportedContainerVersion)

        var wrongHeaderLength = canonical
        replaceUInt32(&wrongHeaderLength, at: 20, with: UInt32.max)
        assertDecode(wrongHeaderLength, key: key, throws: .invalidHeaderLength)

        var wrongKeyLength = canonical
        replaceUInt32(&wrongKeyLength, at: 24, with: UInt32.max)
        assertDecode(wrongKeyLength, key: key, throws: .invalidKeyLength)

        var invalidKey = canonical
        invalidKey[layout.keyOffset] ^= 0xFF
        assertDecode(invalidKey, key: key, throws: .invalidCanonicalKey)

        assertDecode(canonical, key: otherKey, filenameDigest: otherKey.storageDigestHex, throws: .keyMismatch)
        assertDecode(canonical, key: key, filenameDigest: String(repeating: "a", count: 64), throws: .filenameDigestMismatch)
        assertDecode(canonical, key: key, filenameDigest: key.storageDigestHex.uppercased(), throws: .filenameDigestMismatch)

        var wrongSchema = canonical
        replaceUInt32(&wrongSchema, at: layout.schemaOffset, with: key.pipelineIdentity.artifactSchemaVersion + 1)
        assertDecode(wrongSchema, key: key, throws: .schemaMismatch)

        var invalidKind = canonical
        invalidKind[layout.kindOffset] = 0xFF
        assertDecode(invalidKind, key: key, throws: .invalidOutcomeKind)

        var mismatchedKind = canonical
        mismatchedKind[layout.kindOffset] = 2
        assertDecode(mismatchedKind, key: key, throws: .outcomeKindMismatch)

        var hugePayload = canonical
        replaceUInt64(&hugePayload, at: layout.payloadLengthOffset, with: UInt64.max)
        assertDecode(hugePayload, key: key, throws: .invalidPayloadLength)

        var wrongChecksum = canonical
        wrongChecksum[layout.checksumOffset] ^= 0xFF
        assertDecode(wrongChecksum, key: key, throws: .checksumMismatch)

        var wrongSummaryVersion = canonical
        replaceUInt32(&wrongSummaryVersion, at: layout.summaryVersionOffset, with: 2)
        assertDecode(wrongSummaryVersion, key: key, throws: .invalidSummary)

        var wrongSummaryCount = canonical
        replaceUInt32(&wrongSummaryCount, at: layout.summaryCountOffset, with: 19)
        assertDecode(wrongSummaryCount, key: key, throws: .invalidSummary)

        var wrongSummaryValue = canonical
        replaceUInt64(&wrongSummaryValue, at: layout.summaryFieldsOffset, with: 999)
        assertDecode(wrongSummaryValue, key: key, throws: .invalidSummary)

        var malformedPayload = canonical
        malformedPayload[layout.headerByteCount] = UInt8(ascii: "[")
        rewritePayloadChecksum(&malformedPayload, layout: layout)
        assertDecode(malformedPayload, key: key, throws: .payloadDecodeFailed)

        let noncanonicalPayload = canonical.subdata(in: layout.headerByteCount ..< canonical.count) + Data([0x20])
        var noncanonical = canonical.prefix(layout.headerByteCount) + noncanonicalPayload
        replaceUInt64(&noncanonical, at: layout.payloadLengthOffset, with: UInt64(noncanonicalPayload.count))
        rewritePayloadChecksum(&noncanonical, layout: parseLayout(noncanonical))
        assertDecode(noncanonical, key: key, throws: .nonCanonicalPayload)
    }

    func testStrictFramingRejectsEveryTruncationTrailingBytesAndConfiguredBounds() throws {
        let key = try makeKey(sourceText: "bounded framing")
        let canonical = try CodeMapArtifactContainer.encode(key: key, outcome: .ready(makeArtifact()))
        for byteCount in 0 ..< canonical.count {
            XCTAssertThrowsError(
                try CodeMapArtifactContainer.decode(
                    Data(canonical.prefix(byteCount)),
                    expectedKey: key,
                    filenameDigest: key.storageDigestHex
                )
            )
        }
        assertDecode(canonical + Data([0]), key: key, throws: .trailingBytes)

        let payloadBound = CodeMapArtifactContainerPolicy(
            maximumPayloadByteCount: 1,
            maximumContainerByteCount: 64 * 1024
        )
        assertDecode(canonical, key: key, policy: payloadBound, throws: .invalidPayloadLength)

        let collectionBound = CodeMapArtifactContainerPolicy(
            maximumCollectionEntryCount: 1
        )
        assertDecode(canonical, key: key, policy: collectionBound, throws: .collectionLimitExceeded)

        let stringBound = CodeMapArtifactContainerPolicy(
            maximumStringCount: 1,
            maximumStringUTF8ByteCount: 1,
            maximumIndividualStringUTF8ByteCount: 1
        )
        assertDecode(canonical, key: key, policy: stringBound, throws: .stringLimitExceeded)

        let nestingBound = CodeMapArtifactContainerPolicy(maximumJSONNestingDepth: 1)
        assertDecode(canonical, key: key, policy: nestingBound, throws: .collectionLimitExceeded)

        let tokenBound = CodeMapArtifactContainerPolicy(maximumJSONTokenCount: 1)
        assertDecode(canonical, key: key, policy: tokenBound, throws: .collectionLimitExceeded)

        XCTAssertThrowsError(
            try CodeMapArtifactContainer.encode(
                key: key,
                outcome: .ready(makeArtifact()),
                policy: payloadBound
            )
        ) { error in
            XCTAssertEqual(error as? CodeMapArtifactContainerError, .invalidPayloadLength)
        }
    }

    func testFileStoreCreatesPrivateShardedLayoutAndSupportsImmutableIdempotence() throws {
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CodeMapArtifactFileStore(rootURL: root)
        let key = try makeKey(sourceText: "private layout")
        let outcome = CodeMapSyntaxArtifactOutcome.ready(makeArtifact())

        XCTAssertEqual(try store.read(key: key), .miss)
        XCTAssertEqual(try store.write(key: key, outcome: outcome), .inserted)
        XCTAssertEqual(try store.write(key: key, outcome: outcome), .alreadyPresent)
        XCTAssertEqual(try store.read(key: key), .hit(outcome))

        let artifactURL = store.artifactURL(for: key)
        XCTAssertEqual(artifactURL.lastPathComponent, key.storageDigestHex)
        XCTAssertEqual(artifactURL.deletingLastPathComponent().lastPathComponent, key.shard)
        XCTAssertEqual(permissions(at: root.appendingPathComponent("CodeMapArtifacts")), 0o700)
        XCTAssertEqual(permissions(at: root.appendingPathComponent("CodeMapArtifacts/v1")), 0o700)
        XCTAssertEqual(permissions(at: root.appendingPathComponent("CodeMapArtifacts/v1/artifacts")), 0o700)
        XCTAssertEqual(permissions(at: artifactURL.deletingLastPathComponent()), 0o700)
        XCTAssertEqual(permissions(at: artifactURL), 0o600)

        XCTAssertThrowsError(try store.write(key: key, outcome: .readyNoSymbols)) { error in
            XCTAssertEqual(error as? CodeMapArtifactFileStoreError, .integrityCollision)
        }
        XCTAssertEqual(try store.read(key: key), .hit(outcome))
    }

    func testCorruptDestinationQuarantinesToMissAndCanBeAtomicallyReplaced() throws {
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CodeMapArtifactFileStore(rootURL: root)
        let key = try makeKey(sourceText: "corrupt replacement")
        let artifactURL = store.artifactURL(for: key)

        XCTAssertEqual(try store.write(key: key, outcome: .readyNoSymbols), .inserted)
        try Data("corrupt".utf8).write(to: artifactURL)
        XCTAssertEqual(chmod(artifactURL.path, 0o600), 0)
        XCTAssertEqual(try store.read(key: key), .miss)
        XCTAssertFalse(FileManager.default.fileExists(atPath: artifactURL.path))
        XCTAssertEqual(try store.write(key: key, outcome: .readyNoSymbols), .inserted)
        XCTAssertEqual(try store.read(key: key), .hit(.readyNoSymbols))

        let quarantine = root.appendingPathComponent("CodeMapArtifacts/v1/quarantine")
        let names = try recursiveRelativePaths(at: quarantine)
        XCTAssertTrue(names.contains { $0.contains("/artifacts/\(key.shard)/\(key.storageDigestHex).") })
    }

    func testRootsComponentsShardsAndLeavesRejectSymlinkTypeModeAndContainmentAttacks() throws {
        let fileManager = FileManager.default

        let unsafeModeRoot = try makeSecureRoot()
        defer { try? fileManager.removeItem(at: unsafeModeRoot) }
        XCTAssertEqual(chmod(unsafeModeRoot.path, 0o755), 0)
        XCTAssertThrowsError(try CodeMapArtifactFileStore(rootURL: unsafeModeRoot))

        let realRoot = try makeSecureRoot()
        let symlinkParent = try makeSecureRoot()
        defer {
            try? fileManager.removeItem(at: realRoot)
            try? fileManager.removeItem(at: symlinkParent)
        }
        let rootLink = symlinkParent.appendingPathComponent("root-link")
        XCTAssertEqual(symlink(realRoot.path, rootLink.path), 0)
        XCTAssertThrowsError(try CodeMapArtifactFileStore(rootURL: rootLink))

        let componentRoot = try makeSecureRoot()
        let componentTarget = try makeSecureRoot()
        defer {
            try? fileManager.removeItem(at: componentRoot)
            try? fileManager.removeItem(at: componentTarget)
        }
        XCTAssertEqual(
            symlink(componentTarget.path, componentRoot.appendingPathComponent("CodeMapArtifacts").path),
            0
        )
        XCTAssertThrowsError(try CodeMapArtifactFileStore(rootURL: componentRoot))

        let root = try makeSecureRoot()
        let external = try makeSecureRoot()
        defer {
            try? fileManager.removeItem(at: root)
            try? fileManager.removeItem(at: external)
        }
        let store = try CodeMapArtifactFileStore(rootURL: root)
        let key = try makeKey(sourceText: "leaf attacks")
        let artifactURL = store.artifactURL(for: key)
        let shardURL = artifactURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: shardURL, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let externalFile = external.appendingPathComponent("external")
        try Data("external".utf8).write(to: externalFile)
        XCTAssertEqual(chmod(externalFile.path, 0o600), 0)
        XCTAssertEqual(symlink(externalFile.path, artifactURL.path), 0)
        XCTAssertThrowsError(try store.read(key: key))
        try fileManager.removeItem(at: artifactURL)

        try fileManager.createDirectory(
            at: artifactURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        XCTAssertThrowsError(try store.read(key: key))
        try fileManager.removeItem(at: artifactURL)

        XCTAssertEqual(mkfifo(artifactURL.path, 0o600), 0)
        XCTAssertThrowsError(try store.read(key: key))
        try fileManager.removeItem(at: artifactURL)

        XCTAssertEqual(try store.write(key: key, outcome: .readyNoSymbols), .inserted)
        XCTAssertEqual(chmod(artifactURL.path, 0o644), 0)
        XCTAssertThrowsError(try store.read(key: key))

        let traversalRoot = root.appendingPathComponent("missing/..", isDirectory: true)
        XCTAssertThrowsError(try CodeMapArtifactFileStore(rootURL: traversalRoot))
    }

    func testMaintenanceLockAndShardReplacementAreNeverFollowed() throws {
        let fileManager = FileManager.default
        let root = try makeSecureRoot()
        let external = try makeSecureRoot()
        defer {
            try? fileManager.removeItem(at: root)
            try? fileManager.removeItem(at: external)
        }
        let store = try CodeMapArtifactFileStore(rootURL: root)
        let key = try makeKey(sourceText: "component replacement")
        let versionURL = root.appendingPathComponent("CodeMapArtifacts/v1")
        let lockURL = versionURL.appendingPathComponent("maintenance.lock")
        try fileManager.removeItem(at: lockURL)
        XCTAssertEqual(symlink(external.appendingPathComponent("lock").path, lockURL.path), 0)
        XCTAssertThrowsError(try CodeMapArtifactFileStore(rootURL: root))
        try fileManager.removeItem(at: lockURL)
        _ = try CodeMapArtifactFileStore(rootURL: root)

        let shardURL = store.artifactURL(for: key).deletingLastPathComponent()
        XCTAssertEqual(symlink(external.path, shardURL.path), 0)
        XCTAssertThrowsError(try store.write(key: key, outcome: .readyNoSymbols))
        XCTAssertTrue(fileManager.fileExists(atPath: external.path))
    }

    func testRecoveryRemovesOnlyStrictInactiveOwnedRegularTempsAndLookupIgnoresPartials() throws {
        let fileManager = FileManager.default
        let root = try makeSecureRoot()
        defer { try? fileManager.removeItem(at: root) }
        let store = try CodeMapArtifactFileStore(rootURL: root)
        let key = try makeKey(sourceText: "partial temp")
        let shardURL = store.artifactURL(for: key).deletingLastPathComponent()
        try fileManager.createDirectory(at: shardURL, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])

        let inactivePID = Int32.max
        let strictName = ".tmp.\(inactivePID).00000000-0000-0000-0000-000000000001"
        let strictURL = shardURL.appendingPathComponent(strictName)
        try Data("partial".utf8).write(to: strictURL)
        XCTAssertEqual(chmod(strictURL.path, 0o600), 0)

        let privateRemovalURL = shardURL.appendingPathComponent(
            ".delete.\(inactivePID).00000000-0000-0000-0000-000000000004"
        )
        try Data("moved-before-crash".utf8).write(to: privateRemovalURL)
        XCTAssertEqual(chmod(privateRemovalURL.path, 0o600), 0)

        let activeName = ".tmp.\(getpid()).00000000-0000-0000-0000-000000000002"
        let activeURL = shardURL.appendingPathComponent(activeName)
        try Data("active".utf8).write(to: activeURL)
        XCTAssertEqual(chmod(activeURL.path, 0o600), 0)

        let malformedURL = shardURL.appendingPathComponent(".tmp.bad.not-a-uuid")
        try Data("malformed".utf8).write(to: malformedURL)
        XCTAssertEqual(chmod(malformedURL.path, 0o600), 0)

        let symlinkName = ".tmp.\(inactivePID).00000000-0000-0000-0000-000000000003"
        let symlinkURL = shardURL.appendingPathComponent(symlinkName)
        XCTAssertEqual(symlink(activeURL.path, symlinkURL.path), 0)

        XCTAssertEqual(try store.read(key: key), .miss)
        XCTAssertEqual(try store.recoverValidatedTemporaryFiles(), 2)
        XCTAssertFalse(fileManager.fileExists(atPath: strictURL.path))
        XCTAssertFalse(fileManager.fileExists(atPath: privateRemovalURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: activeURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: malformedURL.path))
        XCTAssertNotNil(try? fileManager.destinationOfSymbolicLink(atPath: symlinkURL.path))
    }

    func testArtifactAndQuarantineBytesAndNamesDoNotLeakSourcePathOrRuntimeIdentity() throws {
        let sentinel = "/private/Repository/Worktree/Session/source.swift"
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CodeMapArtifactFileStore(rootURL: root)
        let key = try makeKey(sourceText: sentinel)
        XCTAssertEqual(try store.write(key: key, outcome: .readyNoSymbols), .inserted)

        let namespace = root.appendingPathComponent("CodeMapArtifacts")
        for relativePath in try recursiveRelativePaths(at: namespace) {
            XCTAssertFalse(relativePath.localizedCaseInsensitiveContains("repository"))
            XCTAssertFalse(relativePath.localizedCaseInsensitiveContains("worktree"))
            XCTAssertFalse(relativePath.localizedCaseInsensitiveContains("session"))
            XCTAssertFalse(relativePath.contains("source.swift"))
        }
        let bytes = try Data(contentsOf: store.artifactURL(for: key))
        XCTAssertNil(bytes.range(of: Data(sentinel.utf8)))
        XCTAssertNil(bytes.range(of: Data("worktree".utf8)))
        XCTAssertNil(bytes.range(of: Data("session".utf8)))
    }

    private struct ContainerLayout {
        let headerByteCount: Int
        let keyOffset: Int
        let schemaOffset: Int
        let kindOffset: Int
        let payloadLengthOffset: Int
        let checksumOffset: Int
        let summaryVersionOffset: Int
        let summaryCountOffset: Int
        let summaryFieldsOffset: Int
    }

    private func parseLayout(_ data: Data) -> ContainerLayout {
        let keyOffset = 28
        let keyLength = Int(readUInt32(data, at: 24))
        let schemaOffset = keyOffset + keyLength
        return ContainerLayout(
            headerByteCount: Int(readUInt32(data, at: 20)),
            keyOffset: keyOffset,
            schemaOffset: schemaOffset,
            kindOffset: schemaOffset + 4,
            payloadLengthOffset: schemaOffset + 5,
            checksumOffset: schemaOffset + 13,
            summaryVersionOffset: schemaOffset + 45,
            summaryCountOffset: schemaOffset + 49,
            summaryFieldsOffset: schemaOffset + 53
        )
    }

    private func assertDecode(
        _ data: Data,
        key: CodeMapArtifactKey,
        filenameDigest: String? = nil,
        policy: CodeMapArtifactContainerPolicy = .default,
        throws expected: CodeMapArtifactContainerError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try CodeMapArtifactContainer.decode(
                data,
                expectedKey: key,
                filenameDigest: filenameDigest ?? key.storageDigestHex,
                policy: policy
            ),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(error as? CodeMapArtifactContainerError, expected, file: file, line: line)
        }
    }

    private func rewritePayloadChecksum(_ data: inout Data, layout: ContainerLayout) {
        let payload = data.subdata(in: layout.headerByteCount ..< data.count)
        data.replaceSubrange(
            layout.checksumOffset ..< layout.checksumOffset + 32,
            with: Data(SHA256.hash(data: payload))
        )
    }

    private func makeKey(sourceText: String) throws -> CodeMapArtifactKey {
        let identity = try SyntaxManager().pipelineIdentity(for: .swift, decoderPolicy: .workspaceAutomaticV1)
        return try CodeMapArtifactKey(source: makeSource(text: sourceText), pipelineIdentity: identity)
    }

    private func makeSource(text: String) -> CodeMapSourceSnapshot {
        let data = Data(text.utf8)
        let fingerprint = FileContentFingerprint(
            deviceID: 1,
            fileNumber: 2,
            byteSize: Int64(data.count),
            modificationSeconds: 3,
            modificationNanoseconds: 0,
            statusChangeSeconds: 4,
            statusChangeNanoseconds: 0
        )
        return CodeMapSourceSnapshot(
            validatedContent: ValidatedRawFileContentSnapshot(
                data: data,
                modificationDate: fingerprint.modificationDate,
                fingerprint: fingerprint
            )
        )
    }

    private func makeArtifact() -> CodeMapSyntaxArtifact {
        CodeMapSyntaxArtifact(
            imports: ["Foundation", "CryptoKit"],
            exports: ["Example"],
            classes: [
                ClassInfo(
                    name: "Example",
                    methods: [
                        FunctionInfo(
                            name: "run",
                            parameters: [ParameterInfo(externalName: nil, localName: "value", typeName: "Int")],
                            returnType: "Void",
                            definitionLine: "func run(value: Int) -> Void",
                            lineNumber: 4
                        )
                    ],
                    properties: [PropertyInfo(name: "count", typeName: "Int")]
                )
            ],
            interfaces: [InterfaceInfo(name: "Runnable")],
            aliases: [TypeAliasInfo(name: "Count", definitionLine: "typealias Count = Int")],
            literalUnions: ["one | two"],
            functions: [
                FunctionInfo(
                    name: "helper",
                    parameters: [],
                    returnType: nil,
                    definitionLine: "func helper()",
                    lineNumber: nil
                )
            ],
            enums: [EnumInfo(name: "State", cases: ["ready", "done"])],
            globalVars: [VariableInfo(name: "global", typeName: "Int", definitionLine: "let global: Int")],
            macros: ["DEBUG"],
            referencedTypes: ["Int", "Void"]
        )
    }

    private func permissions(at url: URL) -> Int {
        var status = stat()
        XCTAssertEqual(lstat(url.path, &status), 0)
        return Int(status.st_mode & mode_t(0o777))
    }

    private func recursiveRelativePaths(at root: URL) throws -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsPackageDescendants]
        ) else { return [] }
        return enumerator.compactMap { value in
            guard let url = value as? URL else { return nil }
            return String(url.path.dropFirst(root.path.count + 1))
        }
    }

    private func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        data[offset ..< offset + 4].reduce(into: UInt32(0)) { result, byte in
            result = (result << 8) | UInt32(byte)
        }
    }

    private func replaceUInt32(_ data: inout Data, at offset: Int, with value: UInt32) {
        data[offset] = UInt8((value >> 24) & 0xFF)
        data[offset + 1] = UInt8((value >> 16) & 0xFF)
        data[offset + 2] = UInt8((value >> 8) & 0xFF)
        data[offset + 3] = UInt8(value & 0xFF)
    }

    private func replaceUInt64(_ data: inout Data, at offset: Int, with value: UInt64) {
        for index in 0 ..< 8 {
            data[offset + index] = UInt8((value >> UInt64(56 - index * 8)) & 0xFF)
        }
    }
}

private extension NSLock {
    func withLock(_ body: () -> Void) {
        lock()
        defer { unlock() }
        body()
    }
}

private func makeSecureRoot() throws -> URL {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("CodeMapArtifactContainerTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: base,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
    )
    let resolvedPath = try XCTUnwrap(base.path.withCString { pointer -> String? in
        guard let resolved = realpath(pointer, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    })
    let resolved = URL(fileURLWithPath: resolvedPath, isDirectory: true)
    XCTAssertEqual(chmod(resolved.path, 0o700), 0)
    return resolved
}

// MARK: - Root manifest target cache

#if DEBUG
    final class CodeMapRootManifestTargetCacheTests: XCTestCase {
        func testTargetInspectionReusesValidatedSnapshotsAcrossWarmAndColdStores() async throws {
            let fixture = try await makeFixture(recordCount: 2)
            let inserted = try await fixture.publish()
            XCTAssertEqual(inserted, .inserted(manifestGeneration: 1))
            let published = await fixture.store.debugPublicationMetrics(namespace: fixture.namespace)
            for _ in 0 ..< 3 {
                let result = try await fixture.publish()
                XCTAssertEqual(result, .unchanged(manifestGeneration: 1))
            }
            let warm = await fixture.store.debugPublicationMetrics(namespace: fixture.namespace)
            XCTAssertEqual(warm.publicationCount, published.publicationCount)
            XCTAssertEqual(warm.decodedByteVolume, published.decodedByteVolume)
            XCTAssertGreaterThan(warm.inputSnapshotByteVolume, published.inputSnapshotByteVolume)

            let fileSize = try UInt64(Data(contentsOf: fixture.manifestURL).count)
            let cold = try CodeMapRootManifestStore(rootURL: fixture.root)
            var decodedByteCounts: [UInt64] = []
            for _ in 0 ..< 3 {
                let result = try await fixture.publish(using: cold)
                XCTAssertEqual(result, .unchanged(manifestGeneration: 1))
                let metrics = await cold.debugPublicationMetrics(namespace: fixture.namespace)
                try decodedByteCounts.append(XCTUnwrap(metrics.lastAttempt).decodedByteCount)
            }
            XCTAssertEqual(decodedByteCounts, [fileSize, 0, 0])
        }

        func testTargetRewriteInvalidatesCachedSnapshot() async throws {
            let fixture = try await makeFixture()
            _ = try await fixture.publish()
            let replacement = try CodeMapRootManifestCodec.encode(snapshot: CodeMapRootManifestSnapshot(
                namespace: fixture.namespace,
                authority: fixture.authority,
                manifestGeneration: 9,
                lastAccessEpochSeconds: 100,
                records: []
            ))
            // The rewrite keeps inode, length, and mtime but still changes ctime, so the stale
            // snapshot must be rejected by the combined identity and checksum match.
            try overwriteInPlacePreservingModificationDate(fixture.manifestURL, with: replacement)
            let result = try await fixture.publish()
            XCTAssertEqual(result, .unchanged(manifestGeneration: 9))
            let metrics = await fixture.store.debugPublicationMetrics(namespace: fixture.namespace)
            XCTAssertEqual(try XCTUnwrap(metrics.lastAttempt).decodedByteCount, UInt64(replacement.count))
        }

        func testInvalidTargetsAreReplacedInsteadOfReused() async throws {
            let fixture = try await makeFixture(recordCount: 2)
            _ = try await fixture.publish()
            let intended = try CodeMapRootManifestSnapshot(
                namespace: fixture.namespace,
                authority: fixture.authority,
                manifestGeneration: 1,
                lastAccessEpochSeconds: 100,
                records: fixture.records
            )

            var corrupt = try Data(contentsOf: fixture.manifestURL)
            corrupt[corrupt.count - 1] ^= 1
            try overwriteInPlacePreservingModificationDate(fixture.manifestURL, with: corrupt)
            let afterCorruption = try await fixture.publish()
            XCTAssertEqual(afterCorruption, .replaced(manifestGeneration: 1))
            XCTAssertEqual(try fixture.decodeManifestOnDisk(), intended)

            // A valid checksum does not prove canonical serialization, so this still needs a decode.
            let malformed = try resealedManifest(Data(contentsOf: fixture.manifestURL)) { $0.append(0) }
            XCTAssertNoThrow(try CodeMapRootManifestCodec.validatedContentChecksum(malformed))
            try malformed.write(to: fixture.manifestURL)
            let cold = try CodeMapRootManifestStore(rootURL: fixture.root)
            let afterMalformation = try await fixture.publish(using: cold)
            XCTAssertEqual(afterMalformation, .replaced(manifestGeneration: 1))
            let metrics = await cold.debugPublicationMetrics(namespace: fixture.namespace)
            XCTAssertEqual(try XCTUnwrap(metrics.lastAttempt).decodedByteCount, UInt64(malformed.count))
            XCTAssertEqual(try fixture.decodeManifestOnDisk(), intended)
        }

        func testOverPolicyTargetDoesNotPopulateSharedCaches() async throws {
            let fixture = try await makeFixture(recordCount: 2)
            _ = try await fixture.publish()
            let limited = try CodeMapRootManifestStore(rootURL: fixture.root, policy: policy(records: 1))
            do {
                _ = try await fixture.publish(using: limited)
                XCTFail("Expected record quota rejection")
            } catch {
                XCTAssertEqual(error as? CodeMapRootManifestStoreError, .quotaExceeded)
            }
            let entries = await limited.decodedManifestCacheEntryCountForTesting()
            XCTAssertEqual(entries, 0)
            let accounting = try await limited.accounting()
            XCTAssertEqual(accounting.manifestCount, 0)
        }

        func testScanSummariesSurviveDecodedSnapshotBudgetPressure() async throws {
            let fixture = try await makeFixture()
            _ = try await fixture.publish()

            let refusing = try CodeMapRootManifestStore(rootURL: fixture.root, policy: policy(cacheBytes: 1))
            try await assertScansDecodeEachManifestOnce(
                "one-byte budget retains no snapshot",
                fixture: fixture,
                store: refusing,
                manifestCount: 1,
                cacheBytes: 1,
                maximumRetainedSnapshots: 0
            )

            let secondNamespace = try fixture.sibling(0xB)
            _ = try await fixture.store.updateCurrentManifest(
                namespace: secondNamespace, authority: fixture.authority, records: [], lastAccessEpochSeconds: 100
            )
            let oneManifestByteCount = try UInt64(Data(contentsOf: fixture.manifestURL).count)
            let secondByteCount = try UInt64(Data(contentsOf: fixture.store.manifestURL(for: secondNamespace)).count)
            XCTAssertEqual(secondByteCount, oneManifestByteCount)
            let evicting = try CodeMapRootManifestStore(
                rootURL: fixture.root,
                policy: policy(cacheBytes: oneManifestByteCount)
            )
            try await assertScansDecodeEachManifestOnce(
                "one-manifest budget evicts on every decode",
                fixture: fixture,
                store: evicting,
                manifestCount: 2,
                cacheBytes: oneManifestByteCount,
                maximumRetainedSnapshots: 1
            )
        }

        func testScanSummaryRejectsChangedAndCorruptBytes() async throws {
            let fixture = try await makeFixture()
            _ = try await fixture.publish()
            let limited = try CodeMapRootManifestStore(rootURL: fixture.root, policy: policy(cacheBytes: 1))
            _ = try await limited.accounting()
            let decodesBeforeRewrite = await limited.scanDecodeCountForTesting()
            XCTAssertEqual(decodesBeforeRewrite, 1)

            let replacement = try CodeMapRootManifestCodec.encode(snapshot: CodeMapRootManifestSnapshot(
                namespace: fixture.namespace,
                authority: fixture.authority,
                manifestGeneration: 9,
                lastAccessEpochSeconds: 100,
                records: []
            ))
            try overwriteInPlacePreservingModificationDate(fixture.manifestURL, with: replacement)
            let afterRewrite = try await limited.accounting()
            XCTAssertEqual(afterRewrite.manifestCount, 1)
            let decodesAfterRewrite = await limited.scanDecodeCountForTesting()
            XCTAssertEqual(decodesAfterRewrite, 2)

            var corrupt = replacement
            corrupt[corrupt.count - 1] ^= 1
            try overwriteInPlacePreservingModificationDate(fixture.manifestURL, with: corrupt)
            let afterCorruption = try await limited.accounting()
            XCTAssertEqual(afterCorruption.manifestCount, 0)
            XCTAssertEqual(afterCorruption.corruptManifestCount, 1)
            let decodesAfterCorruption = await limited.scanDecodeCountForTesting()
            XCTAssertEqual(decodesAfterCorruption, 2)
        }

        func testAnonymousEnumContributionRoundTripsWithoutEmptyGraphNames() async throws {
            let artifact = CodeMapSyntaxArtifact(
                imports: [],
                classes: [],
                functions: [],
                enums: [
                    EnumInfo(name: "", cases: ["REPTYPE_MIN", "REPTYPE_MAX"]),
                    EnumInfo(name: "Mode", cases: ["fast", "slow"])
                ],
                globalVars: [],
                macros: [],
                referencedTypes: ["", "Foo"]
            )
            // The artifact keeps the anonymous enum; only the graph contribution drops its empty name.
            XCTAssertTrue(artifact.definedTypeNames.contains(""))

            let fixture = try await makeFixture(recordCount: 1, outcome: .ready(artifact))
            let result = try await fixture.publish()
            XCTAssertEqual(result, .inserted(manifestGeneration: 1))

            let published = try CodeMapRootManifestSnapshot(
                namespace: fixture.namespace,
                authority: fixture.authority,
                manifestGeneration: 1,
                lastAccessEpochSeconds: 100,
                records: fixture.records
            )
            let decoded = try fixture.decodeManifestOnDisk()
            XCTAssertEqual(decoded, published)
            let envelope = try XCTUnwrap(decoded.records.first?.contributionEnvelope)
            XCTAssertEqual(envelope.sortedUniqueDefinitions, ["Mode"])
            XCTAssertEqual(envelope.sortedUniqueReferences, ["Foo"])
        }

        func testTemporaryDecodeFailurePreservesPublishedManifest() async throws {
            let fixture = try await makeFixture(recordCount: 1)
            _ = try await fixture.publish()
            let publishedBytes = try Data(contentsOf: fixture.manifestURL)
            let shard = fixture.manifestURL.deletingLastPathComponent()
            let store = try CodeMapRootManifestStore(
                rootURL: fixture.root,
                hooks: CodeMapRootManifestStoreHooks(faultAction: { point in
                    if point == .afterTemporaryFileSync {
                        corruptOnlyTemporaryManifest(in: shard)
                    }
                    return .proceed
                })
            )
            do {
                // The same records are written again only when the access time moves by 60 seconds or more.
                _ = try await fixture.publish(using: store, lastAccessEpochSeconds: 200)
                XCTFail("Expected the corrupted temporary manifest to fail decode")
            } catch {
                XCTAssertEqual(error as? CodeMapRootManifestDecodeFailure, .invalidMagic)
            }

            XCTAssertEqual(try Data(contentsOf: fixture.manifestURL), publishedBytes)
            let onDisk = try fixture.decodeManifestOnDisk()
            XCTAssertEqual(onDisk.manifestGeneration, 1)
            XCTAssertEqual(onDisk.lastAccessEpochSeconds, 100)
            XCTAssertEqual(try temporaryManifestNames(in: shard), [])
            let metrics = await store.debugPublicationMetrics(namespace: fixture.namespace)
            let attempt = try XCTUnwrap(metrics.lastAttempt)
            XCTAssertFalse(attempt.published)
            XCTAssertFalse(attempt.succeeded)
        }

        func testPostRenameMutationIsRejectedBeforeCaching() async throws {
            let fixture = try await makeFixture(recordCount: 1)
            let manifestURL = fixture.manifestURL
            let replacement = try CodeMapRootManifestCodec.encode(snapshot: CodeMapRootManifestSnapshot(
                namespace: fixture.namespace,
                authority: fixture.authority,
                manifestGeneration: 9,
                lastAccessEpochSeconds: 100,
                records: fixture.records
            ))
            let store = try CodeMapRootManifestStore(
                rootURL: fixture.root,
                hooks: CodeMapRootManifestStoreHooks(afterPublishRename: {
                    do {
                        try overwriteInPlacePreservingModificationDate(manifestURL, with: replacement)
                    } catch {
                        XCTFail("Couldn't rewrite the published manifest: \(error)")
                    }
                })
            )
            do {
                _ = try await fixture.publish(using: store)
                XCTFail("Expected the rewritten manifest to be rejected")
            } catch {
                XCTAssertEqual(error as? CodeMapRootManifestStoreError, .insecureLeaf)
            }

            let cachedSnapshotCount = await store.decodedManifestCacheEntryCountForTesting()
            XCTAssertEqual(cachedSnapshotCount, 0)
            let metrics = await store.debugPublicationMetrics(namespace: fixture.namespace)
            let attempt = try XCTUnwrap(metrics.lastAttempt)
            XCTAssertTrue(attempt.published)
            XCTAssertFalse(attempt.succeeded)
        }

        func testFirstPublicationCleansCorruptManifestsAboveCap() async throws {
            let fixture = try await makeFixture()
            _ = try await fixture.publish()
            let validBytes = try Data(contentsOf: fixture.manifestURL)
            for index in 1 ... 3 {
                let namespace = try fixture.sibling(index)
                _ = try await fixture.store.updateCurrentManifest(
                    namespace: namespace, authority: fixture.authority, records: [], lastAccessEpochSeconds: 100
                )
                let url = fixture.store.manifestURL(for: namespace)
                // Like the production backlog, the checksum is valid and only decode rejects the file.
                let corrupt = try resealedManifest(Data(contentsOf: url)) { $0[0] ^= 1 }
                try overwriteInPlacePreservingModificationDate(url, with: corrupt)
            }
            let storeVersion = fixture.root.appendingPathComponent("CodeMapRootManifests/v1", isDirectory: true)
            let manifests = storeVersion.appendingPathComponent("manifests", isDirectory: true)
            let quarantine = storeVersion.appendingPathComponent("quarantine", isDirectory: true)
            for index in 0 ..< 4 {
                XCTAssertTrue(FileManager.default.createFile(
                    atPath: quarantine.appendingPathComponent("seeded.corrupt.\(index)").path,
                    contents: Data([UInt8(index)]),
                    attributes: [.posixPermissions: 0o600]
                ))
            }
            XCTAssertEqual(try regularFilePaths(under: manifests).count, 4)
            XCTAssertEqual(try regularFilePaths(under: quarantine).count, 4)

            let maintained = expectation(description: "maintenance after the first publication")
            let store = try CodeMapRootManifestStore(
                rootURL: fixture.root,
                policy: policy(manifests: 2, quarantine: 2, entries: 16),
                hooks: CodeMapRootManifestStoreHooks(beforeTerminalAuthorityCheck: { operation in
                    if operation == .maintenance {
                        maintained.fulfill()
                    }
                }),
                runsMaintenanceAfterFirstPublication: true
            )
            let published = try fixture.sibling(4)
            let result = try await store.updateCurrentManifest(
                namespace: published, authority: fixture.authority, records: [], lastAccessEpochSeconds: 100
            )
            XCTAssertEqual(result, .inserted(manifestGeneration: 1))
            await fulfillment(of: [maintained], timeout: 5)
            // The pass doesn't suspend after its terminal hook, so this call runs after the pass ends.
            let accounting = try await store.accounting()

            XCTAssertEqual(accounting.manifestCount, 2)
            XCTAssertEqual(accounting.corruptManifestCount, 0)
            XCTAssertEqual(accounting.quarantineCount, 2)
            XCTAssertEqual(try regularFilePaths(under: manifests), Set([fixture.manifestURL, store.manifestURL(for: published)].map {
                $0.pathComponents.suffix(2).joined(separator: "/")
            }))
            XCTAssertEqual(try Data(contentsOf: fixture.manifestURL), validBytes)
            XCTAssertEqual(try regularFilePaths(under: quarantine).count, 2)
        }

        func testLowercaseHexMatchesFormattedEncoding() {
            let allBytes = Data((0 ... 255).map { UInt8($0) })
            XCTAssertEqual(allBytes.lowercaseHex, allBytes.map { String(format: "%02x", $0) }.joined())
            XCTAssertEqual(Data().lowercaseHex, "")
            let slice = allBytes[250 ..< 256]
            XCTAssertNotEqual(slice.startIndex, 0)
            XCTAssertEqual(slice.lowercaseHex, "fafbfcfdfeff")
        }

        /// Runs complete scans on a cold store whose decoded-snapshot budget is too small for its
        /// manifests: only scan summaries can keep later scans from decoding again.
        private func assertScansDecodeEachManifestOnce(
            _ scenario: String,
            fixture: Fixture,
            store: CodeMapRootManifestStore,
            manifestCount: Int,
            cacheBytes: UInt64,
            maximumRetainedSnapshots: Int
        ) async throws {
            let initial = try await store.accounting()
            XCTAssertEqual(initial.manifestCount, manifestCount, scenario)
            let decodesAfterFirstScan = await store.scanDecodeCountForTesting()
            XCTAssertEqual(decodesAfterFirstScan, manifestCount, scenario)
            for _ in 0 ..< 3 {
                let accounting = try await store.accounting()
                XCTAssertEqual(accounting, initial, scenario)
            }
            let decodesAfterRescans = await store.scanDecodeCountForTesting()
            XCTAssertEqual(decodesAfterRescans, manifestCount, scenario)
            let entries = await store.decodedManifestCacheEntryCountForTesting()
            let bytes = await store.decodedManifestCacheByteCountForTesting()
            XCTAssertLessThanOrEqual(entries, maximumRetainedSnapshots, scenario)
            XCTAssertLessThanOrEqual(bytes, cacheBytes, scenario)

            let republished = try await fixture.publish(using: store)
            XCTAssertEqual(republished, .unchanged(manifestGeneration: 1), scenario)
            _ = try await store.accounting()
            let decodesAfterRepublish = await store.scanDecodeCountForTesting()
            XCTAssertEqual(decodesAfterRepublish, manifestCount, scenario)
        }

        private func policy(
            records: Int = 100_000,
            cacheBytes: UInt64 = 64 * 1024 * 1024,
            manifests: Int = CodeMapRootManifestStorePolicy.default.maximumManifestCount,
            quarantine: Int = CodeMapRootManifestStorePolicy.default.maximumQuarantineCount,
            entries: Int = CodeMapRootManifestStorePolicy.default.maintenanceEntryLimit
        ) -> CodeMapRootManifestStorePolicy {
            let defaults = CodeMapRootManifestStorePolicy.default
            return CodeMapRootManifestStorePolicy(
                maximumRecordCountPerManifest: records,
                maximumManifestByteCount: defaults.maximumManifestByteCount,
                maximumManifestCount: manifests,
                maximumStoreByteCount: defaults.maximumStoreByteCount,
                maximumQuarantineCount: quarantine,
                maintenanceEntryLimit: entries,
                maximumDecodedManifestCacheByteCount: cacheBytes
            )
        }

        private struct Fixture {
            let root: URL
            let store: CodeMapRootManifestStore
            let namespace: CodeMapRootManifestNamespace
            let authority: CodeMapRootManifestAuthority
            let records: [CodeMapRootManifestRecord]

            var manifestURL: URL {
                store.manifestURL(for: namespace)
            }

            /// The fixture's namespace with the worktree identity `wt_` followed by 64 copies of
            /// `index` in hex, so each index from 0 to 15 except 10 names another namespace.
            func sibling(_ index: Int) throws -> CodeMapRootManifestNamespace {
                try CodeMapRootManifestNamespace(
                    repositoryNamespace: namespace.repositoryNamespace,
                    worktreeIdentity: "wt_" + String(repeating: String(index, radix: 16), count: 64),
                    repositoryRelativeLoadedRootPrefix: "",
                    objectFormat: .sha1,
                    pipelineIdentity: namespace.pipelineIdentity,
                    repositoryBindingEpoch: "repository",
                    worktreeBindingEpoch: "worktree"
                )
            }

            func publish(
                using other: CodeMapRootManifestStore? = nil,
                lastAccessEpochSeconds: UInt64 = 100
            ) async throws -> CodeMapRootManifestWriteResult {
                try await (other ?? store).updateCurrentManifest(
                    namespace: namespace,
                    authority: authority,
                    records: records,
                    lastAccessEpochSeconds: lastAccessEpochSeconds
                )
            }

            func decodeManifestOnDisk() throws -> CodeMapRootManifestSnapshot {
                try CodeMapRootManifestCodec.decode(
                    Data(contentsOf: manifestURL),
                    expectedNamespace: namespace,
                    filenameDigest: namespace.storageDigestHex
                )
            }
        }

        private func makeFixture(
            recordCount: Int = 0,
            outcome: CodeMapSyntaxArtifactOutcome = .readyNoSymbols
        ) async throws -> Fixture {
            let root = try makeSecureRoot()
            addTeardownBlock { try? FileManager.default.removeItem(at: root) }
            let pipeline = try SyntaxManager().pipelineIdentity(for: .swift, decoderPolicy: .workspaceAutomaticV1)
            let namespace = try CodeMapRootManifestNamespace(
                repositoryNamespace: GitBlobRepositoryNamespace(rawValue: String(repeating: "ab", count: 32)),
                worktreeIdentity: "wt_" + String(repeating: "a", count: 64),
                repositoryRelativeLoadedRootPrefix: "",
                objectFormat: .sha1,
                pipelineIdentity: pipeline,
                repositoryBindingEpoch: "repository",
                worktreeBindingEpoch: "worktree"
            )
            let authority = try CodeMapRootManifestAuthority(
                authorityGeneration: 1, repositoryBindingEpoch: "repository", worktreeBindingEpoch: "worktree",
                layoutGeneration: "layout", indexGeneration: "index", checkoutConfigurationGeneration: "checkout",
                attributeGeneration: "attributes", sparseGeneration: "sparse", metadataGeneration: "metadata"
            )
            let key = CodeMapArtifactKey(
                rawSHA256: CodeMapRawSourceDigest(bytes: Data(repeating: 1, count: 32)),
                rawByteCount: 1, pipelineIdentity: pipeline
            )
            let artifacts = try CodeMapArtifactStore(rootURL: root)
            _ = try await artifacts.insert(key: key, deterministicOutcome: outcome)
            guard case let .hit(_, handle) = try await artifacts.lookup(key: key) else {
                throw CodeMapArtifactFileStoreError.integrityCollision
            }
            let association = try VerifiedGitBlobCodeMapLocatorAssociation.revalidatePersisted(
                identity: GitBlobCodeMapLocatorIdentity(
                    repositoryNamespace: namespace.repositoryNamespace, objectFormat: .sha1,
                    blobOID: String(repeating: "a", count: 40), pipelineIdentity: pipeline
                ),
                artifactKey: key, casHandle: handle
            )
            let contribution = if case let .ready(artifact) = outcome {
                CodeMapSelectionGraphContribution(artifactKey: key, artifact: artifact)
            } else {
                CodeMapSelectionGraphContribution(artifactKey: key, definitions: [], references: [])
            }
            let records = try (0 ..< recordCount).map { index in
                try CodeMapRootManifestRecord.verifiedClean(
                    namespace: namespace, repositoryRelativePath: String(format: "File%06d.swift", index),
                    gitMode: .regular, association: association, contribution: contribution,
                    authority: authority, bindingGeneration: 1
                )
            }
            return try Fixture(
                root: root,
                store: CodeMapRootManifestStore(rootURL: root),
                namespace: namespace,
                authority: authority,
                records: records
            )
        }
    }

    /// Rewrites a file of the same size in place and restores its access and modification times to
    /// the nanosecond, so the status-change time is the only identity field the write changes.
    /// Foundation's `setAttributes` would round the modification time to microseconds.
    private func overwriteInPlacePreservingModificationDate(_ url: URL, with data: Data) throws {
        var original = stat()
        XCTAssertEqual(lstat(url.path, &original), 0)
        XCTAssertEqual(Int(original.st_size), data.count)
        let handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: data)
        try handle.close()
        var times = [original.st_atimespec, original.st_mtimespec]
        XCTAssertEqual(utimensat(AT_FDCWD, url.path, &times, AT_SYMLINK_NOFOLLOW), 0)
    }

    /// Applies `change` to a manifest's payload and replaces the SHA-256 trailer with the payload's
    /// new digest, so the result passes the checksum check.
    private func resealedManifest(_ manifest: Data, changingPayload change: (inout Data) -> Void) -> Data {
        var payload = Data(manifest.dropLast(SHA256.byteCount))
        change(&payload)
        payload.append(contentsOf: SHA256.hash(data: payload))
        return payload
    }

    /// Paths of the regular files below `directory`, relative to it.
    private func regularFilePaths(under directory: URL) throws -> Set<String> {
        try Set(FileManager.default.subpathsOfDirectory(atPath: directory.path).filter { path in
            try directory.appendingPathComponent(path).resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
        })
    }

    private func temporaryManifestNames(in shard: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: shard.path).filter { $0.hasPrefix(".tmp.") }
    }

    /// Changes the magic of the shard's one temporary manifest and recomputes its checksum in place,
    /// keeping its inode and size, so only canonical decode can reject the file.
    private func corruptOnlyTemporaryManifest(in shard: URL) {
        do {
            let names = try temporaryManifestNames(in: shard)
            XCTAssertEqual(names.count, 1)
            guard let name = names.first else { return }
            let url = shard.appendingPathComponent(name)
            // The payload starts with the codec's magic.
            let corrupt = try resealedManifest(Data(contentsOf: url)) { $0[0] ^= 1 }
            try overwriteInPlacePreservingModificationDate(url, with: corrupt)
        } catch {
            XCTFail("Couldn't corrupt the temporary manifest: \(error)")
        }
    }
#endif
