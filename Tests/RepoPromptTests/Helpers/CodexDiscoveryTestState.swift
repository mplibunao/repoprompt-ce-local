import Foundation
@testable import RepoPromptApp

/// Snapshot of the process-wide Codex discovery state: the registry's live models and the
/// `CodexDynamicModelRecords` cache in standard defaults. Catalog and recommendation code read
/// both, so tests capture them before installing fixture models and restore them afterwards.
struct CodexDiscoveryTestState {
    private static let recordsKey = "CodexDynamicModelRecords"

    private let liveModels: [CodexAppServerClient.RemoteModel]
    private let recordsData: Data?

    static func capture() -> CodexDiscoveryTestState {
        CodexDiscoveryTestState(
            liveModels: AgentCodexModelRegistry.shared.currentLiveModels(),
            recordsData: UserDefaults.standard.data(forKey: recordsKey)
        )
    }

    func restore() {
        _ = AgentCodexModelRegistry.shared.updateLiveModels(liveModels)
        if let recordsData {
            UserDefaults.standard.set(recordsData, forKey: Self.recordsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.recordsKey)
        }
    }

    /// Installs `models` as the live Codex catalog; an empty list also clears the cache so
    /// resolution falls back to the static list, as it does before any discovery.
    static func setDiscoveredModels(_ models: [CodexAppServerClient.RemoteModel]) {
        _ = AgentCodexModelRegistry.shared.updateLiveModels(models)
        if models.isEmpty {
            UserDefaults.standard.removeObject(forKey: recordsKey)
        }
    }

    /// GPT-6 Sol (provider default) and Luna advertising every supported effort, defaulting to Medium.
    static func gpt6Models() -> [CodexAppServerClient.RemoteModel] {
        let efforts = ["low", "medium", "high", "xhigh", "max"]
        return [
            remoteModel("gpt-6-sol", efforts: efforts, defaultEffort: "medium", isDefault: true),
            remoteModel("gpt-6-luna", efforts: efforts, defaultEffort: "medium")
        ]
    }

    static func remoteModel(
        _ id: String,
        efforts: [String],
        defaultEffort: String? = nil,
        isDefault: Bool = false
    ) -> CodexAppServerClient.RemoteModel {
        CodexAppServerClient.RemoteModel(
            id: id,
            model: id,
            displayName: id,
            description: "",
            isDefault: isDefault,
            supportedReasoningEfforts: efforts.map { .init(reasoningEffort: $0, description: "") },
            defaultReasoningEffort: defaultEffort ?? efforts.first
        )
    }
}
