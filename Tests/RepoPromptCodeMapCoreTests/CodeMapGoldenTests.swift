import XCTest
@testable import RepoPromptCodeMapCore

final class CodeMapGoldenTests: XCTestCase {
    func testFixturesMatchGoldenCodeMapDescriptions() throws {
        // `language` is set only where the engine doesn't map the fixtures' extension to a language.
        let groups: [(name: String, relativePaths: [String], maximumCount: Int, language: LanguageType?)] = [
            ("CE/core", CodeMapFixtureRunner.fixtureRelativePaths, 5, nil),
            ("expanded languages", CodeMapFixtureRunner.expandedLanguageFixtureRelativePaths, 5, nil),
            ("edge fixtures", CodeMapFixtureRunner.edgeFixtureRelativePaths, 3, nil),
            ("Terraform", CodeMapFixtureRunner.terraformFixtureRelativePaths, 5, .terraform)
        ]

        for group in groups {
            let fixtures = try CodeMapFixtureRunner.loadFixtures(relativePaths: group.relativePaths)
            XCTAssertEqual(fixtures.map(\.relativePath), group.relativePaths, group.name)
            XCTAssertEqual(fixtures.count, group.relativePaths.count, group.name)
            XCTAssertLessThanOrEqual(fixtures.count, group.maximumCount, group.name)

            let tempRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("CodeMapGoldenTests", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempRoot) }

            for fixture in fixtures {
                let rendered = try CodeMapFixtureRunner.renderArtifactCodeMap(
                    for: fixture,
                    tempRoot: tempRoot,
                    language: group.language
                )
                let expected = try CodeMapFixtureRunner.expectedCodeMap(for: fixture)
                XCTAssertEqual(rendered, expected, fixture.relativePath)
            }
        }
    }
}
