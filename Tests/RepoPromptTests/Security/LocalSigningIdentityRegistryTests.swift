import Darwin
@testable import RepoPromptApp
import XCTest

final class LocalSigningIdentityRegistryTests: XCTestCase {
    private let team = "ABCDE12345"
    private let service = "com.pvncher.repoprompt.ce.local-apple-development.ABCDE12345.keychain.v7"
    private var validRecord: LocalSigningIdentityRecord {
        LocalSigningIdentityRecord(schemaVersion: 2, teamIdentifier: team, keychainService: service)
    }

    func testLoadsOwnerOnlyVersionedRecord() throws {
        let url = try writeRegistry(validRecord)

        XCTAssertEqual(LocalSigningIdentityRegistry.load(from: url), .success(validRecord))
    }

    func testRejectsMissingWrongOwnerInsecureAndMalformedRegistry() throws {
        let directory = try temporaryDirectory()
        let missing = directory.appendingPathComponent("missing.json")
        XCTAssertEqual(LocalSigningIdentityRegistry.load(from: missing), .failure(.missing))

        let valid = try writeRegistry(validRecord, in: directory)
        XCTAssertEqual(
            LocalSigningIdentityRegistry.load(from: valid, expectedOwnerID: getuid() + 1),
            .failure(.wrongOwner)
        )

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: valid.path)
        XCTAssertEqual(LocalSigningIdentityRegistry.load(from: valid), .failure(.insecurePermissions))

        try "not-json".write(to: valid, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: valid.path)
        XCTAssertEqual(LocalSigningIdentityRegistry.load(from: valid), .failure(.invalidRecord))
    }

    func testRejectsSchemaOneAndRecordsThatRouteOutsideLocalServices() throws {
        let directory = try temporaryDirectory()
        // A self-signed build's record; the installer rewrites it before a team-signed build runs.
        let schemaOne = directory.appendingPathComponent("schema-one.json")
        try Data(
            #"{"schemaVersion":1,"certificateName":"RepoPrompt CE Local Self-Signed Code Signing","certificateSHA256":"\#(String(repeating: "A", count: 64))","serviceGeneration":7}"#.utf8
        ).write(to: schemaOne)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: schemaOne.path)
        XCTAssertEqual(LocalSigningIdentityRegistry.load(from: schemaOne), .failure(.invalidRecord))

        for record in [
            LocalSigningIdentityRecord(schemaVersion: 2, teamIdentifier: "abcde12345", keychainService: service),
            LocalSigningIdentityRecord(schemaVersion: 2, teamIdentifier: team, keychainService: KeychainService.officialV2ServiceName)
        ] {
            let url = try writeRegistry(record, in: directory)
            XCTAssertEqual(LocalSigningIdentityRegistry.load(from: url), .failure(.invalidRecord), "\(record)")
        }
    }

    func testSigningContextRequiresMatchingSignedMetadataAndRegistry() {
        XCTAssertEqual(
            RuntimeCodeSigningPolicy.localSigningContext(
                bundleTeamIdentifier: team.lowercased(),
                bundleKeychainService: service,
                registryResult: .success(validRecord)
            ),
            .valid(
                RuntimeLocalSigningExpectation(
                    bundleTeamIdentifier: team,
                    registeredTeamIdentifier: team,
                    bundleKeychainService: service,
                    registeredKeychainService: service
                )
            )
        )
        XCTAssertEqual(
            RuntimeCodeSigningPolicy.localSigningContext(
                bundleTeamIdentifier: nil,
                bundleKeychainService: service,
                registryResult: .success(validRecord)
            ),
            .invalid(.localIdentityMetadataUnavailable)
        )
        XCTAssertEqual(
            RuntimeCodeSigningPolicy.localSigningContext(
                bundleTeamIdentifier: team,
                bundleKeychainService: "com.pvncher.repoprompt.ce.local-apple-development.ABCDE12345.keychain.v8",
                registryResult: .success(validRecord)
            ),
            .invalid(.localIdentityContinuityMismatch)
        )
        XCTAssertEqual(
            RuntimeCodeSigningPolicy.localSigningContext(
                bundleTeamIdentifier: team,
                bundleKeychainService: service,
                registryResult: .failure(.insecurePermissions)
            ),
            .invalid(.localIdentityRegistryUnavailable)
        )
    }

    private func writeRegistry(_ record: LocalSigningIdentityRecord, in directory: URL? = nil) throws -> URL {
        let directory = try directory ?? temporaryDirectory()
        let url = directory.appendingPathComponent("local-signing-identity-v1.json")
        let data = try JSONEncoder().encode(record)
        try data.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}
