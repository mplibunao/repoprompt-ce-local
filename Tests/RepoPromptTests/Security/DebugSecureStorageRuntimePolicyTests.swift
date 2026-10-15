@testable import RepoPromptApp
import XCTest

final class RuntimeCodeSigningPolicyTests: XCTestCase {
    func testVerifiedPersistentDomainsRouteToIsolatedServices() {
        let official = RuntimeCodeSigningInfo.synthetic(
            codeIdentifier: RuntimeCodeSigningPolicy.developerIDBundleIdentifier,
            teamIdentifier: RuntimeCodeSigningPolicy.signingTeamIdentifier,
            validatedDomains: [.developerID]
        )
        let localTeam = "ABCDE12345"
        let localService = "com.pvncher.repoprompt.ce.local-apple-development.ABCDE12345.keychain.v3"
        let localExpectation = RuntimeLocalSigningExpectation(
            bundleTeamIdentifier: localTeam,
            registeredTeamIdentifier: localTeam,
            bundleKeychainService: localService,
            registeredKeychainService: localService
        )
        let local = RuntimeCodeSigningInfo.synthetic(
            codeIdentifier: RuntimeCodeSigningPolicy.developerIDBundleIdentifier,
            teamIdentifier: localTeam,
            validatedDomains: [.localAppleDevelopment]
        )
        let debug = RuntimeCodeSigningInfo.synthetic(
            codeIdentifier: RuntimeCodeSigningPolicy.appleDevelopmentDebugBundleIdentifier,
            teamIdentifier: RuntimeCodeSigningPolicy.signingTeamIdentifier,
            validatedDomains: [.appleDevelopmentDebug]
        )

        assertDecision(
            marker: "developer-id",
            debugMarker: "keychain",
            signingInfo: official,
            expectedDomain: .officialDeveloperID
        )
        assertDecision(
            marker: "local-apple-development",
            debugMarker: "keychain",
            signingInfo: local,
            localSigningContext: .valid(localExpectation),
            expectedDomain: .localAppleDevelopment,
            expectedLocalKeychainService: localService
        )
        assertDecision(
            marker: "debug-apple-development",
            debugMarker: "keychain",
            signingInfo: debug,
            expectedDomain: .appleDevelopmentDebug
        )

        XCTAssertTrue(
            SecureKeyValueStorageFactory.selection(
                for: RuntimeSecureStorageDecision(domain: .officialDeveloperID, rejectionReason: nil)
            ).backend === KeychainService.officialV2Shared
        )
        let localSelection = SecureKeyValueStorageFactory.selection(
            for: RuntimeSecureStorageDecision(
                domain: .localAppleDevelopment,
                rejectionReason: nil,
                localKeychainService: localService
            )
        )
        XCTAssertEqual((localSelection.backend as? KeychainService)?.serviceName, localService)
        XCTAssertTrue(
            SecureKeyValueStorageFactory.selection(
                for: RuntimeSecureStorageDecision(
                    domain: .localAppleDevelopment,
                    rejectionReason: nil,
                    localKeychainService: KeychainService.officialV2ServiceName
                )
            ).backend === EphemeralSecureKeyValueStore.shared
        )
        XCTAssertTrue(
            SecureKeyValueStorageFactory.selection(
                for: RuntimeSecureStorageDecision(domain: .appleDevelopmentDebug, rejectionReason: nil)
            ).backend === KeychainService.debugShared
        )
    }

    func testSuccessorIdentityRequiresExactMarkerAndSignaturePairing() {
        let successor = RuntimeCodeSigningInfo.synthetic(
            codeIdentifier: RuntimeCodeSigningPolicy.successorDeveloperIDBundleIdentifier,
            teamIdentifier: RuntimeCodeSigningPolicy.successorSigningTeamIdentifier,
            validatedDomains: [.successorDeveloperID]
        )
        let legacy = RuntimeCodeSigningInfo.synthetic(
            codeIdentifier: RuntimeCodeSigningPolicy.developerIDBundleIdentifier,
            teamIdentifier: RuntimeCodeSigningPolicy.signingTeamIdentifier,
            validatedDomains: [.developerID]
        )

        assertDecision(
            marker: "successor-developer-id",
            debugMarker: nil,
            signingInfo: successor,
            expectedDomain: .successorOfficialDeveloperID
        )

        // Cross-pairings between markers and signatures must fail closed.
        let mismatches: [(String, RuntimeCodeSigningInfo)] = [
            ("successor-developer-id", legacy),
            ("developer-id", successor),
            ("successor-developer-id", RuntimeCodeSigningInfo.synthetic(
                codeIdentifier: RuntimeCodeSigningPolicy.successorDeveloperIDBundleIdentifier,
                teamIdentifier: RuntimeCodeSigningPolicy.signingTeamIdentifier,
                validatedDomains: [.successorDeveloperID]
            )),
            ("successor-developer-id", RuntimeCodeSigningInfo.synthetic(
                codeIdentifier: RuntimeCodeSigningPolicy.successorDeveloperIDBundleIdentifier,
                teamIdentifier: RuntimeCodeSigningPolicy.successorSigningTeamIdentifier,
                validatedDomains: [.developerID]
            )),
            ("successor-developer-id", RuntimeCodeSigningInfo.synthetic(
                codeIdentifier: RuntimeCodeSigningPolicy.successorDeveloperIDBundleIdentifier,
                teamIdentifier: RuntimeCodeSigningPolicy.successorSigningTeamIdentifier,
                isAdHoc: true,
                validatedDomains: [.successorDeveloperID]
            ))
        ]
        for (marker, signingInfo) in mismatches {
            assertDecision(
                marker: marker,
                debugMarker: nil,
                signingInfo: signingInfo,
                expectedDomain: .ephemeral,
                expectedReason: .markerSignatureMismatch
            )
        }
    }

    func testSuccessorDomainStaysEphemeralUntilBridgeOverrideAndAcceptsOverride() {
        let decision = RuntimeSecureStorageDecision(
            domain: .successorOfficialDeveloperID,
            rejectionReason: nil
        )

        // Without a committed-bridge override the successor identity must not
        // fall back to the legacy Keychain service.
        XCTAssertTrue(
            SecureKeyValueStorageFactory.selection(for: decision).backend === EphemeralSecureKeyValueStore.shared
        )

        XCTAssertTrue(SecureKeyValueStorageFactory.officialOverrideApplies(to: .officialDeveloperID))
        XCTAssertTrue(SecureKeyValueStorageFactory.officialOverrideApplies(to: .successorOfficialDeveloperID))
        XCTAssertFalse(SecureKeyValueStorageFactory.officialOverrideApplies(to: .localAppleDevelopment))
        XCTAssertFalse(SecureKeyValueStorageFactory.officialOverrideApplies(to: .appleDevelopmentDebug))
        XCTAssertFalse(SecureKeyValueStorageFactory.officialOverrideApplies(to: .ephemeral))
    }

    func testRejectedModesExhaustivelyFailClosedToEphemeralStorage() {
        let official = RuntimeCodeSigningInfo.synthetic(
            codeIdentifier: RuntimeCodeSigningPolicy.developerIDBundleIdentifier,
            teamIdentifier: RuntimeCodeSigningPolicy.signingTeamIdentifier,
            validatedDomains: [.developerID]
        )
        let debug = RuntimeCodeSigningInfo.synthetic(
            codeIdentifier: RuntimeCodeSigningPolicy.appleDevelopmentDebugBundleIdentifier,
            teamIdentifier: RuntimeCodeSigningPolicy.signingTeamIdentifier,
            validatedDomains: [.appleDevelopmentDebug]
        )
        let invalid = RuntimeCodeSigningInfo.synthetic(failure: .signatureInvalid)

        let cases: [(String?, String?, RuntimeCodeSigningInfo, RuntimeSecureStorageRejectionReason)] = [
            (nil, nil, official, .missingSigningModeMarker),
            ("", nil, official, .missingSigningModeMarker),
            ("unknown", nil, official, .unknownSigningModeMarker),
            ("release-candidate-adhoc", nil, official, .releaseCandidate),
            ("debug-adhoc", "alternate-in-memory", debug, .adHocDebug),
            ("debug-apple-development", "alternate-in-memory", debug, .debugEphemeralRequested),
            ("debug-apple-development", nil, debug, .missingDebugStorageMarker),
            ("debug-apple-development", "unknown", debug, .unknownDebugStorageMarker),
            ("developer-id", nil, invalid, .signingValidationFailed),
            ("developer-id", nil, debug, .markerSignatureMismatch),
            ("local-apple-development", nil, official, .localIdentityRegistryUnavailable),
            ("debug-apple-development", "keychain", official, .markerSignatureMismatch),
            ("developer-id", nil, RuntimeCodeSigningInfo.synthetic(
                codeIdentifier: RuntimeCodeSigningPolicy.developerIDBundleIdentifier,
                teamIdentifier: RuntimeCodeSigningPolicy.signingTeamIdentifier,
                isAdHoc: true,
                validatedDomains: [.developerID]
            ), .markerSignatureMismatch)
        ]

        for (marker, debugMarker, signingInfo, expectedReason) in cases {
            let decision = RuntimeCodeSigningPolicy.decision(
                signingModeMarker: marker,
                debugStorageMarker: debugMarker,
                signingInfo: signingInfo
            )
            XCTAssertEqual(decision, RuntimeSecureStorageDecision(domain: .ephemeral, rejectionReason: expectedReason))
            XCTAssertTrue(SecureKeyValueStorageFactory.selection(for: decision).backend === EphemeralSecureKeyValueStore.shared)
        }
    }

    func testPersistentDomainsRequireExactIdentifierAndTeam() {
        let wrongIdentifier = RuntimeCodeSigningInfo.synthetic(
            codeIdentifier: "com.example.other",
            teamIdentifier: RuntimeCodeSigningPolicy.signingTeamIdentifier,
            validatedDomains: [.developerID]
        )
        let wrongTeam = RuntimeCodeSigningInfo.synthetic(
            codeIdentifier: RuntimeCodeSigningPolicy.developerIDBundleIdentifier,
            teamIdentifier: "OTHERTEAM",
            validatedDomains: [.developerID]
        )

        for signingInfo in [wrongIdentifier, wrongTeam] {
            assertDecision(
                marker: "developer-id",
                debugMarker: nil,
                signingInfo: signingInfo,
                expectedDomain: .ephemeral,
                expectedReason: .markerSignatureMismatch
            )
        }
    }

    func testLocalSigningExpectationRequiresMatchingTeamAndService() {
        let team = "ABCDE12345"
        let service = "com.pvncher.repoprompt.ce.local-self-signed.\(String(repeating: "ab", count: 32)).keychain.v4"
        XCTAssertEqual(
            RuntimeLocalSigningExpectation(
                bundleTeamIdentifier: team.lowercased(),
                registeredTeamIdentifier: team,
                bundleKeychainService: service,
                registeredKeychainService: service
            ).validatedIdentity,
            RuntimeValidatedLocalSigningIdentity(teamIdentifier: team, keychainService: service)
        )
        XCTAssertNil(
            RuntimeLocalSigningExpectation(
                bundleTeamIdentifier: team,
                registeredTeamIdentifier: "VWXYZ67890",
                bundleKeychainService: service,
                registeredKeychainService: service
            ).validatedIdentity
        )
        XCTAssertNil(
            RuntimeLocalSigningExpectation(
                bundleTeamIdentifier: team,
                registeredTeamIdentifier: team,
                bundleKeychainService: service,
                registeredKeychainService: "com.pvncher.repoprompt.ce.local-apple-development.ABCDE12345.keychain.v4"
            ).validatedIdentity
        )
        XCTAssertNil(
            RuntimeLocalSigningExpectation(
                bundleTeamIdentifier: team,
                registeredTeamIdentifier: team,
                bundleKeychainService: KeychainService.debugServiceName,
                registeredKeychainService: KeychainService.debugServiceName
            ).validatedIdentity
        )
    }

    func testLocalPersistenceFailsClosedWithoutMatchingRegistryContextOrTeam() {
        let team = "ABCDE12345"
        let service = "com.pvncher.repoprompt.ce.local-apple-development.ABCDE12345.keychain.v4"
        let signingInfo = RuntimeCodeSigningInfo.synthetic(
            codeIdentifier: RuntimeCodeSigningPolicy.developerIDBundleIdentifier,
            teamIdentifier: team,
            validatedDomains: [.localAppleDevelopment]
        )

        let rejectedContexts: [(RuntimeLocalSigningContext, RuntimeSecureStorageRejectionReason)] = [
            (.invalid(.localIdentityMetadataUnavailable), .localIdentityMetadataUnavailable),
            (.invalid(.localIdentityRegistryUnavailable), .localIdentityRegistryUnavailable),
            (.invalid(.localIdentityContinuityMismatch), .localIdentityContinuityMismatch)
        ]
        for (context, reason) in rejectedContexts {
            assertDecision(
                marker: "local-apple-development",
                debugMarker: "keychain",
                signingInfo: signingInfo,
                localSigningContext: context,
                expectedDomain: .ephemeral,
                expectedReason: reason
            )
        }

        let otherTeamExpectation = RuntimeLocalSigningExpectation(
            bundleTeamIdentifier: "VWXYZ67890",
            registeredTeamIdentifier: "VWXYZ67890",
            bundleKeychainService: service,
            registeredKeychainService: service
        )
        assertDecision(
            marker: "local-apple-development",
            debugMarker: "keychain",
            signingInfo: signingInfo,
            localSigningContext: .valid(otherTeamExpectation),
            expectedDomain: .ephemeral,
            expectedReason: .markerSignatureMismatch
        )
    }

    func testCompileTimeTrustAnchorsIncludeExpectedCertificateClasses() {
        XCTAssertEqual(RuntimeCodeSigningPolicy.developerIDBundleIdentifier, "com.pvncher.repoprompt.ce")
        XCTAssertEqual(RuntimeCodeSigningPolicy.appleDevelopmentDebugBundleIdentifier, "com.pvncher.repoprompt.ce.debug")
        XCTAssertEqual(RuntimeCodeSigningPolicy.signingTeamIdentifier, "648A27MST5")
        XCTAssertEqual(RuntimeCodeSigningPolicy.successorDeveloperIDBundleIdentifier, "com.repoprompt.ce")
        XCTAssertEqual(RuntimeCodeSigningPolicy.successorSigningTeamIdentifier, "69N6K965SF")
        XCTAssertTrue(RuntimeCodeSigningPolicy.developerIDRequirement.contains("1.2.840.113635.100.6.1.13"))
        XCTAssertTrue(RuntimeCodeSigningPolicy.appleDevelopmentDebugRequirement.contains("1.2.840.113635.100.6.1.12"))
        XCTAssertTrue(RuntimeCodeSigningPolicy.successorDeveloperIDRequirement.contains("1.2.840.113635.100.6.1.13"))
        let localRequirement = RuntimeCodeSigningPolicy.localAppleDevelopmentRequirement(teamIdentifier: "ABCDE12345")
        XCTAssertTrue(localRequirement.hasPrefix("anchor apple generic and identifier \"com.pvncher.repoprompt.ce\""))
        XCTAssertTrue(localRequirement.contains("certificate leaf[subject.OU] = \"ABCDE12345\""))
        XCTAssertTrue(localRequirement.contains("1.2.840.113635.100.6.1.12"))
        XCTAssertNotNil(RuntimeCodeSigningDetector.requirement(from: localRequirement))
        XCTAssertEqual(
            RuntimeCodeSigningPolicy.successorDeveloperIDRequirement,
            "anchor apple generic and identifier \"com.repoprompt.ce\" and certificate leaf[subject.OU] = \"69N6K965SF\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
        )
    }

    private func assertDecision(
        marker: String?,
        debugMarker: String?,
        signingInfo: RuntimeCodeSigningInfo,
        localSigningContext: RuntimeLocalSigningContext? = nil,
        expectedDomain: RuntimeSecureStorageDomain,
        expectedReason: RuntimeSecureStorageRejectionReason? = nil,
        expectedLocalKeychainService: String? = nil
    ) {
        XCTAssertEqual(
            RuntimeCodeSigningPolicy.decision(
                signingModeMarker: marker,
                debugStorageMarker: debugMarker,
                signingInfo: signingInfo,
                localSigningContext: localSigningContext
            ),
            RuntimeSecureStorageDecision(
                domain: expectedDomain,
                rejectionReason: expectedReason,
                localKeychainService: expectedLocalKeychainService
            )
        )
    }
}
