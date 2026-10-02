import Foundation
@testable import RepoPromptApp
import XCTest

/// An `APISettingsViewModel` whose saved keys, model seeds, and settings stay inside one test: an
/// in-memory secure store, a temporary settings file, and a unique defaults suite.
@MainActor
struct IsolatedAPISettingsFixture {
    let store: GlobalSettingsStore
    let apiSettings: APISettingsViewModel
    let secureStorage: TestSecureStorageBackend
    let defaults: UserDefaults
    let settingsURL: URL

    /// A new store over the same settings file and defaults suite, as a relaunch would build.
    func reloadStore() -> GlobalSettingsStore {
        GlobalSettingsStore(defaults: defaults, fileStore: GlobalSettingsFileStore(fileURL: settingsURL))
    }
}

extension XCTestCase {
    /// Registers cleanup for the view model's background work, the defaults suite, and the
    /// settings directory.
    @MainActor
    func makeIsolatedAPISettingsFixture(name: String = #function) throws -> IsolatedAPISettingsFixture {
        let namespace = String(describing: type(of: self))
        let directory = try makeTestDirectory(name: name, namespace: namespace)
        let suiteName = "\(namespace).\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let settingsURL = directory.appendingPathComponent("Settings/globalSettings.json")
        let store = GlobalSettingsStore(defaults: defaults, fileStore: GlobalSettingsFileStore(fileURL: settingsURL))
        let secureStorage = TestSecureStorageBackend()
        let keyManager = KeyManager(secureService: SecureKeysService(secureStorage: secureStorage))
        let apiSettings = APISettingsViewModel(
            aiQueriesService: AIQueriesService(keyManager: keyManager),
            keyManager: keyManager,
            loadStoredDataOnInit: false,
            modelSeedSettingsStore: store
        )
        addTeardownBlock { @MainActor in
            apiSettings.prepareForWindowClose()
        }
        return IsolatedAPISettingsFixture(
            store: store,
            apiSettings: apiSettings,
            secureStorage: secureStorage,
            defaults: defaults,
            settingsURL: settingsURL
        )
    }
}
