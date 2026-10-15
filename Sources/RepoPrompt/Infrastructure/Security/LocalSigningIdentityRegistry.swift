import Darwin
import Foundation

/// The installer's record of the Apple Development team that signs local production builds
/// and the Keychain service those builds store secrets in.
struct LocalSigningIdentityRecord: Codable, Equatable {
    static let currentSchemaVersion = 2

    let schemaVersion: Int
    let teamIdentifier: String
    let keychainService: String
}

enum LocalSigningIdentityRegistryError: Error, Equatable {
    case missing
    case notRegularFile
    case wrongOwner
    case insecurePermissions
    case unreadable
    case invalidRecord
}

enum LocalSigningIdentityRegistry {
    /// The file keeps the name schema 1 introduced so archives and restores find it in one
    /// place; `schemaVersion` inside the record versions its contents.
    static let filename = "local-signing-identity-v1.json"

    static func defaultURL(fileManager: FileManager = .default) -> URL? {
        MCPFilesystemConstants.identity.applicationSupportRootURL(fileManager: fileManager)
            .appendingPathComponent(filename)
    }

    static func load(
        from url: URL,
        fileManager: FileManager = .default,
        expectedOwnerID: UInt32 = getuid()
    ) -> Result<LocalSigningIdentityRecord, LocalSigningIdentityRegistryError> {
        _ = fileManager
        var fileStatus = Darwin.stat()
        guard lstat(url.path, &fileStatus) == 0 else {
            return .failure(errno == ENOENT ? .missing : .unreadable)
        }
        guard fileStatus.st_mode & S_IFMT == S_IFREG else {
            return .failure(.notRegularFile)
        }
        guard fileStatus.st_uid == expectedOwnerID else {
            return .failure(.wrongOwner)
        }
        guard fileStatus.st_mode & 0o077 == 0 else {
            return .failure(.insecurePermissions)
        }

        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            return .failure(.unreadable)
        }
        guard let record = try? JSONDecoder().decode(LocalSigningIdentityRecord.self, from: data),
              record.schemaVersion == LocalSigningIdentityRecord.currentSchemaVersion,
              normalizedTeamIdentifier(record.teamIdentifier) == record.teamIdentifier,
              KeychainService.isLocalProductionServiceName(record.keychainService)
        else {
            return .failure(.invalidRecord)
        }
        return .success(record)
    }

    /// Apple Team IDs are ten uppercase letters and digits.
    static func normalizedTeamIdentifier(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard normalized.count == 10,
              normalized.allSatisfy({ ("A" ... "Z").contains($0) || ("0" ... "9").contains($0) })
        else {
            return nil
        }
        return normalized
    }
}
