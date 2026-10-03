import Foundation
import os
import RepoPromptDomainRuntime
import RepoPromptShared

/// Process entry for the app executable. A debug build verifies that its isolated profile cannot
/// resolve into production state before any profile-backed store, window, or runtime exists.
@MainActor
public enum RepoPromptApplicationLauncher {
    public static func main() {
        #if DEBUG
            if let failure = profileIsolationFailure(identity: MCPFilesystemConstants.identity) {
                reportProfileIsolationFailure(failure)
                exit(EX_CONFIG)
            }
        #endif
        RepoPromptApplication.main()
    }

    /// The launch decision, kept apart from process exit so it can run without starting the app.
    nonisolated static func profileIsolationFailure(
        identity: MCPFilesystemIdentity,
        productionStateRoots: [URL]? = nil,
        fileManager: FileManager = .default
    ) -> Error? {
        do {
            try identity.validateProfileIsolation(
                managedStateURLs: managedStateURLs(identity: identity),
                productionStateRoots: productionStateRoots,
                fileManager: fileManager
            )
            return nil
        } catch {
            return error
        }
    }

    /// Fixed locations the app's stores own below the profile's top-level entries, each as its
    /// store resolves it: the domain runtime's state, the managed Codex homes and configuration,
    /// the settings, preset, and identity-diagnostics files, and the backup folders beside them.
    /// Locations named per workspace or per item are checked by their store when it resolves them.
    private nonisolated static func managedStateURLs(identity: MCPFilesystemIdentity) -> [URL] {
        let codex = CodexRuntimeAuthority.statePaths()
        return AppDomainRuntimeComposition.makeConfiguration(
            identity: identity,
            isolatesDebugProfile: true,
            defaults: .standard
        ).managedStateLocations
            + [codex.codexHome, codex.sqliteHome, CodexIntegrationConfiguration.configURL()]
            + [
                GlobalSettingsFileStore.defaultFileURL(),
                GlobalSettingsFileStore.settingsDirectoryURL().appendingPathComponent("Backups", isDirectory: true),
                PresetFileStore.defaultWorkflowFileURL(),
                PresetFileStore.defaultModelFileURL(),
                PresetFileStore.presetsDirectoryURL().appendingPathComponent("Backups", isDirectory: true)
            ]
            + [IdentityTransitionDiagnostics.defaultFileURL()].compactMap(\.self)
    }

    #if DEBUG
        /// Unattended launches cannot answer a modal, so the diagnostic goes to stderr and the
        /// persisted system log, and the process exits before any store starts.
        private static func reportProfileIsolationFailure(_ error: Error) {
            let message = "RepoPrompt CE Debug did not start: \(error)"
            FileHandle.standardError.write(Data((message + "\n").utf8))
            Logger(subsystem: "com.repoprompt.debug-profile", category: "launch")
                .fault("\(message, privacy: .public)")
        }
    #endif
}
