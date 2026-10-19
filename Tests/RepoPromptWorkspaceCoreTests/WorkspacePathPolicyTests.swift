@testable import RepoPromptWorkspaceCore
import XCTest

final class WorkspacePathPolicyTests: XCTestCase {
    func testStandardizedPathsNormalizeAndPreserveContainmentBoundaries() {
        XCTAssertEqual(StandardizedPath.relative("/Sources/./Models/../App.swift/"), "Sources/App.swift")
        XCTAssertEqual(StandardizedPath.join(standardizedRoot: "/repo", standardizedRelativePath: "Sources/App.swift"), "/repo/Sources/App.swift")
        XCTAssertTrue(StandardizedPath.isDescendant("/repo/Sources/App.swift", of: "/repo"))
        XCTAssertFalse(StandardizedPath.isDescendant("/repository/App.swift", of: "/repo"))
        XCTAssertEqual(StandardizedPath.diagnosticEscaped("bad\0path\n"), "bad\\0path\\n")
    }

    /// Bytes are compared because `String` equality treats precomposed and decomposed text as equal.
    func testRelativePathReturnsInputBytesOnlyWhenAlreadyStandard() {
        let cases: [(label: String, input: String, expected: String)] = [
            ("clean", "Sources/Models/App.swift", "Sources/Models/App.swift"),
            ("leading slash", "/Sources/App.swift", "Sources/App.swift"),
            ("trailing slash", "Sources/App.swift/", "Sources/App.swift"),
            ("doubled slash", "Sources//App.swift", "Sources/App.swift"),
            ("leading dot", "./Sources/App.swift", "Sources/App.swift"),
            ("dot component", "Sources/./App.swift", "Sources/App.swift"),
            ("trailing dot", "Sources/.", "Sources"),
            ("dot-dot component", "Sources/Models/../App.swift", "Sources/App.swift"),
            ("trailing dot-dot", "Sources/Models/..", "Sources"),
            ("dot alone", ".", ""),
            ("slash alone", "/", ""),
            ("empty", "", ""),
            ("names starting with dots", ".github/.../a./App.swift", ".github/.../a./App.swift"),
            ("non-ASCII", "Sources/日本語/caf\u{E9}.swift", "Sources/日本語/caf\u{E9}.swift"),
            ("decomposed", "Sources/cafe\u{301}/App.swift", "Sources/cafe\u{301}/App.swift"),
            ("non-ASCII doubled slash", "Sources//cafe\u{301}/App.swift", "Sources/cafe\u{301}/App.swift"),
        ]
        for (label, input, expected) in cases {
            XCTAssertEqual(Array(StandardizedPath.relative(input).utf8), Array(expected.utf8), label)
        }
    }

    /// Foundation's `standardizingPath` is the reference, so rows that depend on the file system
    /// (`/private/tmp` and `/var/automount/tmp` shorten to `/tmp`) hold on any machine.
    func testAbsolutePathReturnsFoundationStandardizedBytes() {
        let inputs: [(label: String, path: String)] = [
            ("clean", "/Users/test/Project/Sources/App.swift"),
            ("trailing slash", "/Users/test/Project/"),
            ("doubled slash", "/Users/test//Project/App.swift"),
            ("dot component", "/Users/test/./Project"),
            ("trailing dot", "/Users/test/Project/."),
            ("dot-dot component", "/Users/test/Project/../Other"),
            ("tilde", "~"),
            ("tilde prefix", "~/Project/App.swift"),
            ("existing /private directory", "/private/tmp"),
            ("missing /private path", "/private/tmp/rpce-missing-\(UUID().uuidString)"),
            ("/var/automount", "/var/automount/tmp"),
            ("non-ASCII", "/Users/test/日本語/caf\u{E9}.swift"),
            ("decomposed", "/Users/test/cafe\u{301}/App.swift"),
            ("1,024 bytes", absolutePath(utf8Count: 1024)),
            ("1,025 bytes, which standardizing truncates", absolutePath(utf8Count: 1025)),
            ("relative", "Sources/App.swift"),
            ("root", "/"),
        ]
        for (label, path) in inputs {
            XCTAssertEqual(
                Array(StandardizedPath.absolute(path).utf8),
                Array((path as NSString).standardizingPath.utf8),
                label
            )
        }
    }

    func testAliasResolutionUsesDeterministicGeneratedAliasesForDuplicateNames() {
        let first = makeRoot(name: "App", fullPath: "/Users/test/Clients/One/App")
        let second = makeRoot(name: "App", fullPath: "/Users/test/Clients/Two/App")
        let roots = [first, second]

        XCTAssertEqual(ClientPathFormatter.nonAbsoluteRootAlias(root: first, visibleRoots: roots), "One/App")
        XCTAssertEqual(ClientPathFormatter.nonAbsoluteRootAlias(root: second, visibleRoots: roots), "Two/App")

        XCTAssertEqual(
            WorkspaceAliasResolver.resolve(
                userPath: "Two/App/Sources/File.swift",
                roots: roots,
                options: RootAliasOptions(requireRemainder: true)
            ),
            .prefixed(root: second, alias: "Two/App", remainder: "Sources/File.swift")
        )
    }

    func testExactFileInputParsesLiteralExplicitAndAbsoluteForms() throws {
        XCTAssertEqual(try WorkspaceExactFileInput.parse("mimic/session.py"), .relative("mimic/session.py"))
        XCTAssertEqual(
            try WorkspaceExactFileInput.parse("One/App//Sources/./File.swift"),
            .explicitRoot(alias: "One/App", relativePath: "Sources/File.swift")
        )
        XCTAssertEqual(
            try WorkspaceExactFileInput.parse("~/Sources/../File.swift"),
            .absolute(StandardizedPath.absolute(("~/Sources/../File.swift" as NSString).expandingTildeInPath))
        )
        XCTAssertEqual(try WorkspaceExactFileInput.parse("App:Sources/File.swift"), .relative("App:Sources/File.swift"))
        XCTAssertEqual(try WorkspaceExactFileInput.parse(" Target.swift"), .relative(" Target.swift"))
        XCTAssertEqual(
            try WorkspaceExactFileInput.parse("~/Project//File.swift"),
            .explicitRoot(alias: "~/Project", relativePath: "File.swift")
        )
    }

    func testExactFileInputRejectsMalformedExplicitQualifier() {
        for input in ["App//", "App///File.swift", "App//Dir//File.swift", "../File.swift"] {
            XCTAssertThrowsError(try WorkspaceExactFileInput.parse(input), "Expected rejection for \(input)")
        }
    }

    func testExplicitWorkspaceFilePathUsesCanonicalGeneratedAlias() {
        let first = makeRoot(name: "App", fullPath: "/Users/test/Clients/One/App")
        let second = makeRoot(name: "App", fullPath: "/Users/test/Clients/Two/App")

        XCTAssertEqual(
            ClientPathFormatter.explicitWorkspaceFilePath(
                root: second,
                relativePath: "Sources/File.swift",
                visibleRoots: [first, second]
            ),
            "root@\(second.id.uuidString.lowercased())//Sources/File.swift"
        )
    }

    func testExactRootAliasesRemainUniqueAcrossDisplayAliasCollisions() {
        let first = makeRoot(name: "Project", fullPath: "/Docs")
        let second = makeRoot(name: "Project", fullPath: "/tmp/Project")
        let canonicalNameCollision = makeRoot(name: "Docs", fullPath: "/else/Docs")
        let generatedAliasCollision = makeRoot(
            name: "root@\(first.id.uuidString.lowercased())",
            fullPath: "/natural/collision"
        )
        let roots = [first, second, canonicalNameCollision, generatedAliasCollision]
        let aliases = ClientPathFormatter.exactRootAliases(visibleRoots: roots)

        XCTAssertEqual(Set(aliases.values.map { $0.lowercased() }).count, roots.count)
        XCTAssertNotEqual(aliases[first.id]?.lowercased(), aliases[canonicalNameCollision.id]?.lowercased())
        XCTAssertTrue(
            ClientPathFormatter.explicitWorkspaceFilePath(
                root: first,
                relativePath: "shared.txt",
                visibleRoots: roots
            ).hasSuffix("//shared.txt")
        )
    }

    func testAmbiguousRootMessageUsesExplicitQualifier() {
        let root = makeRoot(name: "App", fullPath: "/Users/test/App")
        let message = PathResolutionIssueRenderer.message(
            for: .ambiguousRootMatch(input: "Sources/File.swift", candidateRoots: [root])
        )

        XCTAssertTrue(message.contains("<root-alias>//<relative-path>"))
    }

    func testCreatePreflightRejectsAmbiguousAndImplicitMultiRootPaths() {
        let first = makeRoot(name: "App", fullPath: "/Users/test/AppOne")
        let second = makeRoot(name: "App", fullPath: "/Users/test/AppTwo")

        XCTAssertThrowsError(
            try CreatePathPreflight.validate(
                userPath: "App/Sources/File.swift",
                visibleRoots: [first, second]
            )
        ) { error in
            guard case let CreatePathPreflight.Error.ambiguousAlias(alias, matchingRoots) = error else {
                return XCTFail("Expected ambiguousAlias, got \(error)")
            }
            XCTAssertEqual(alias, "App")
            XCTAssertEqual(Set(matchingRoots), Set([first, second]))
        }

        let distinct = makeRoot(name: "Docs", fullPath: "/Users/test/Docs")
        XCTAssertThrowsError(
            try CreatePathPreflight.validate(
                userPath: "Sources/File.swift",
                visibleRoots: [first, distinct]
            )
        ) { error in
            guard case let CreatePathPreflight.Error.missingAliasWithMultipleRoots(loadedRoots) = error else {
                return XCTFail("Expected missingAliasWithMultipleRoots, got \(error)")
            }
            XCTAssertEqual(loadedRoots, [first, distinct])
        }
    }

    func testMovePathResolverRejectsAmbiguousAndCrossRootAliases() throws {
        let source = makeRoot(name: "AppA", fullPath: "/Users/test/AppA")
        let other = makeRoot(name: "AppB", fullPath: "/Users/test/AppB")

        XCTAssertThrowsError(
            try MovePathResolver.resolveRelativePathInRoot(
                userPath: "AppB/Sources/File.swift",
                sourceRoot: source,
                visibleRoots: [source, other]
            )
        ) { error in
            guard case let MovePathResolver.Error.crossRootAlias(alias, resolvedRoot) = error else {
                return XCTFail("Expected crossRootAlias, got \(error)")
            }
            XCTAssertEqual(alias, "AppB")
            XCTAssertEqual(resolvedRoot, other)
        }

        let duplicateA = makeRoot(name: "App", fullPath: "/Users/test/AppOne")
        let duplicateB = makeRoot(name: "App", fullPath: "/Users/test/AppTwo")
        XCTAssertThrowsError(
            try MovePathResolver.resolveRelativePathInRoot(
                userPath: "App/Sources/File.swift",
                sourceRoot: duplicateA,
                visibleRoots: [duplicateA, duplicateB]
            )
        ) { error in
            guard case let MovePathResolver.Error.ambiguousAlias(alias, matchingRoots) = error else {
                return XCTFail("Expected ambiguousAlias, got \(error)")
            }
            XCTAssertEqual(alias, "App")
            XCTAssertEqual(Set(matchingRoots), Set([duplicateA, duplicateB]))
        }
    }

    private func makeRoot(id: UUID = UUID(), name: String, fullPath: String) -> WorkspaceRootRef {
        WorkspaceRootRef(id: id, name: name, fullPath: fullPath)
    }

    private func absolutePath(utf8Count: Int) -> String {
        var path = "/Users/test"
        while path.utf8.count + 10 <= utf8Count {
            path += "/abcdefghi"
        }
        path += String(repeating: "x", count: utf8Count - path.utf8.count)
        return path
    }
}
