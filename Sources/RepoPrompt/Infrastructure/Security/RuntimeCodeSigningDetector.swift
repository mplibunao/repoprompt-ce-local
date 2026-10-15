import Foundation
import Security

struct RuntimeValidatedLocalSigningIdentity: Equatable {
    let teamIdentifier: String
    let keychainService: String
}

/// What a local production bundle says about its signing team and Keychain service, next to
/// what the installer registered. Both must agree before the build may use that service.
struct RuntimeLocalSigningExpectation: Equatable {
    let bundleTeamIdentifier: String
    let registeredTeamIdentifier: String
    let bundleKeychainService: String
    let registeredKeychainService: String

    var validatedIdentity: RuntimeValidatedLocalSigningIdentity? {
        guard let teamIdentifier = LocalSigningIdentityRegistry.normalizedTeamIdentifier(bundleTeamIdentifier),
              teamIdentifier == LocalSigningIdentityRegistry.normalizedTeamIdentifier(registeredTeamIdentifier),
              KeychainService.isLocalProductionServiceName(bundleKeychainService),
              bundleKeychainService == registeredKeychainService
        else {
            return nil
        }
        return RuntimeValidatedLocalSigningIdentity(
            teamIdentifier: teamIdentifier,
            keychainService: bundleKeychainService
        )
    }
}

enum RuntimeCodeSigningDetector {
    static func validatesStaticCode(at executableURL: URL, requirementSource: String) -> Bool {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(executableURL as CFURL, [], &staticCode)
        guard createStatus == errSecSuccess,
              let staticCode,
              let requirement = requirement(from: requirementSource)
        else {
            return false
        }
        return SecStaticCodeCheckValidity(
            staticCode,
            SecCSFlags(rawValue: kSecCSStrictValidate),
            requirement
        ) == errSecSuccess
    }

    static func currentProcessSigningInfo(
        localSigningExpectation: RuntimeLocalSigningExpectation? = nil
    ) -> RuntimeCodeSigningInfo {
        var code: SecCode?
        let selfStatus = SecCodeCopySelf([], &code)
        guard selfStatus == errSecSuccess, let code else {
            return invalidInfo(.codeObjectUnavailable)
        }

        let validityStatus = SecCodeCheckValidity(
            code,
            SecCSFlags(rawValue: kSecCSStrictValidate),
            nil
        )
        guard validityStatus == errSecSuccess else {
            return invalidInfo(.signatureInvalid)
        }

        var staticCode: SecStaticCode?
        let staticStatus = SecCodeCopyStaticCode(code, [], &staticCode)
        guard staticStatus == errSecSuccess, let staticCode else {
            return invalidInfo(.signingInformationUnavailable)
        }

        var information: CFDictionary?
        let informationFlags = SecCSFlags(
            rawValue: kSecCSSigningInformation | kSecCSRequirementInformation
        )
        let infoStatus = SecCodeCopySigningInformation(staticCode, informationFlags, &information)
        guard infoStatus == errSecSuccess, let dictionary = information as? [String: Any] else {
            return invalidInfo(.signingInformationUnavailable)
        }

        let codeIdentifier = normalizedString(dictionary[kSecCodeInfoIdentifier as String])
        let teamIdentifier = normalizedString(dictionary[kSecCodeInfoTeamIdentifier as String])
        let signingFlags = (dictionary[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value
        let isAdHoc = signingFlags.map {
            SecCodeSignatureFlags(rawValue: $0).contains(.adhoc)
        } ?? false

        guard let developerIDRequirement = requirement(from: RuntimeCodeSigningPolicy.developerIDRequirement),
              let successorDeveloperIDRequirement = requirement(
                  from: RuntimeCodeSigningPolicy.successorDeveloperIDRequirement
              ),
              let debugRequirement = requirement(from: RuntimeCodeSigningPolicy.appleDevelopmentDebugRequirement)
        else {
            return RuntimeCodeSigningInfo(
                codeIdentifier: codeIdentifier,
                teamIdentifier: teamIdentifier,
                signingFlags: signingFlags,
                isAdHoc: isAdHoc,
                validationResult: .invalid(.requirementUnavailable)
            )
        }

        var validatedDomains: Set<RuntimeCodeSigningDomain> = []
        if SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), developerIDRequirement) == errSecSuccess {
            validatedDomains.insert(.developerID)
        }
        if SecCodeCheckValidity(
            code,
            SecCSFlags(rawValue: kSecCSStrictValidate),
            successorDeveloperIDRequirement
        ) == errSecSuccess {
            validatedDomains.insert(.successorDeveloperID)
        }
        if SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), debugRequirement) == errSecSuccess {
            validatedDomains.insert(.appleDevelopmentDebug)
        }
        if let expectedTeamIdentifier = localSigningExpectation?.validatedIdentity?.teamIdentifier,
           let localRequirement = requirement(
               from: RuntimeCodeSigningPolicy.localAppleDevelopmentRequirement(teamIdentifier: expectedTeamIdentifier)
           ),
           SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), localRequirement) == errSecSuccess
        {
            validatedDomains.insert(.localAppleDevelopment)
        }

        return RuntimeCodeSigningInfo(
            codeIdentifier: codeIdentifier,
            teamIdentifier: teamIdentifier,
            signingFlags: signingFlags,
            isAdHoc: isAdHoc,
            validationResult: .valid(domains: validatedDomains)
        )
    }

    static func requirement(from source: String) -> SecRequirement? {
        var requirement: SecRequirement?
        let status = SecRequirementCreateWithString(source as CFString, [], &requirement)
        guard status == errSecSuccess else { return nil }
        return requirement
    }

    static func requirementData(from source: String) -> Data? {
        guard let requirement = requirement(from: source) else { return nil }
        var data: CFData?
        guard SecRequirementCopyData(requirement, [], &data) == errSecSuccess,
              let data
        else {
            return nil
        }
        return data as Data
    }

    private static func normalizedString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func invalidInfo(_ category: RuntimeCodeSigningFailureCategory) -> RuntimeCodeSigningInfo {
        RuntimeCodeSigningInfo(
            codeIdentifier: nil,
            teamIdentifier: nil,
            signingFlags: nil,
            isAdHoc: false,
            validationResult: .invalid(category)
        )
    }
}
