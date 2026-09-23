import SwiftUI

/// The probe context a chip host resolves for its target. `.resolved(nil)` builds the
/// legitimate nil-workspace key; `.unavailable` yields no key — no subscription and no
/// workspace-dependent metadata. A throwing resolution would collapse these two, so hosts pass
/// the value instead of a closure.
enum ACPModelParameterProbeContext: Equatable {
    case resolved(String?)
    case unavailable
}

/// Lists every parameter pin for one ACP provider/model row and renders one
/// `ACPModelParameterPinChip` per kind. It owns only metadata acquisition: saved state and
/// write authority stay with the host, which supplies the saved selections, the probe context,
/// and a guarded change handler.
///
/// Metadata comes from `ACPModelParameterResolver.parameterSet`: Cursor's static catalog
/// resolves synchronously, and OpenCode needs one demand-scoped subscription per row, however
/// many chips the row shows. The subscription uses `.task(id:)`, which SwiftUI cancels on view
/// teardown **and** on identity change. Because the identity is the canonical key — which
/// contains the workspace — a workspace switch restarts the probe structurally. Ordinary
/// re-renders don't restart it (same key).
struct ACPModelParameterProbeView: View {
    typealias OpenCodeParameterStreamProvider = @MainActor (
        _ workspacePath: String?,
        _ modelRaw: String
    ) async -> AsyncStream<OpenCodeACPModelParameterSnapshot>

    /// The displayed model this row probes and writes against.
    let modelRaw: String
    let providerID: ACPProviderID
    let providerDisplayName: String
    let probeContext: ACPModelParameterProbeContext
    /// The saved pins, read from the same profile snapshot the host renders.
    let savedSelections: [ACPModelParameterSelection]
    let isEnabled: Bool
    /// Re-checks live host state and applies the edit atomically to the live profile.
    let onChange: (ACPModelParameterPinChange) -> Void
    private let openCodeStreamProvider: OpenCodeParameterStreamProvider

    @State private var snapshot: OpenCodeACPModelParameterSnapshot?

    init(
        modelRaw: String,
        providerID: ACPProviderID,
        providerDisplayName: String,
        probeContext: ACPModelParameterProbeContext,
        savedSelections: [ACPModelParameterSelection],
        isEnabled: Bool = true,
        openCodeStreamProvider: @escaping OpenCodeParameterStreamProvider = { workspacePath, modelRaw in
            await OpenCodeACPModelPollingService.shared.subscribeModelParameters(
                workspacePath: workspacePath,
                modelRaw: modelRaw
            )
        },
        onChange: @escaping (ACPModelParameterPinChange) -> Void
    ) {
        self.modelRaw = modelRaw
        self.providerID = providerID
        self.providerDisplayName = providerDisplayName
        self.probeContext = probeContext
        self.savedSelections = savedSelections
        self.isEnabled = isEnabled
        self.openCodeStreamProvider = openCodeStreamProvider
        self.onChange = onChange
    }

    /// The OpenCode discovery key for the current target, or nil when there is nothing to
    /// acquire (another provider, an empty model, or an unresolved workspace).
    private var probeKey: OpenCodeACPModelParameterKey? {
        Self.openCodeProbeKey(providerID: providerID, modelRaw: modelRaw, probeContext: probeContext)
    }

    private var controls: [ACPModelParameterPinControl] {
        Self.pinControls(
            providerID: providerID,
            modelRaw: modelRaw,
            probeContext: probeContext,
            openCodeSnapshot: snapshot,
            savedSelections: savedSelections
        )
    }

    static func openCodeProbeKey(
        providerID: ACPProviderID,
        modelRaw: String,
        probeContext: ACPModelParameterProbeContext
    ) -> OpenCodeACPModelParameterKey? {
        let trimmed = modelRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard providerID == .openCode, !trimmed.isEmpty,
              case let .resolved(workspacePath) = probeContext
        else { return nil }
        return OpenCodeACPModelParameterKey(workspacePath: workspacePath, modelRaw: trimmed)
    }

    /// The row's controls for the held OpenCode observation, or the static metadata other
    /// providers resolve without a session. An unavailable probe context never becomes a
    /// nil-workspace OpenCode observation.
    static func pinControls(
        providerID: ACPProviderID,
        modelRaw: String,
        probeContext: ACPModelParameterProbeContext,
        openCodeSnapshot: OpenCodeACPModelParameterSnapshot?,
        savedSelections: [ACPModelParameterSelection]
    ) -> [ACPModelParameterPinControl] {
        let parameterSet = ACPModelParameterResolver.parameterSet(
            providerID: providerID,
            selectedModelRaw: modelRaw,
            openCodeKey: openCodeProbeKey(providerID: providerID, modelRaw: modelRaw, probeContext: probeContext),
            openCodeParameters: openCodeSnapshot
        )
        return ACPModelParameterResolver.pinControls(
            providerID: providerID,
            selectedModelRaw: modelRaw,
            parameterSet: parameterSet,
            persistedSelections: savedSelections
        )
    }

    /// A lone OpenCode thinking chip keeps its established unprefixed label; any other row names
    /// each parameter so a bare "Default" is never ambiguous.
    static func showsParameterNames(_ controls: [ACPModelParameterPinControl]) -> Bool {
        !(controls.count == 1 && controls[0].providerID == .openCode && controls[0].kind == .thinking)
    }

    var body: some View {
        let controls = controls
        let showsParameterNames = Self.showsParameterNames(controls)
        HStack(spacing: 0) {
            // Always-present zero-size host for the discovery task.
            //
            // The task CANNOT hang off a chip's own conditional. With no saved pin and no
            // metadata yet, that conditional collapses to nil content, which SwiftUI gives no
            // render node — `.task` is then never scheduled, so the row could never acquire the
            // metadata that would make a chip appear. Verified in isolation: `.task` on a `Group`
            // wrapping nil content does not fire, while this zero-size host does.
            Color.clear
                .frame(width: 0, height: 0)
                .task(id: probeKey) {
                    snapshot = nil
                    guard let probeKey else { return }
                    let stream = await openCodeStreamProvider(probeKey.workspacePath, probeKey.wireModelRaw)
                    for await delivered in stream {
                        // Cancellation is checked explicitly: a cancelled task's body still runs
                        // to its next suspension, so an in-flight delivery could otherwise land
                        // after the target changed and stick until the next remount.
                        guard !Task.isCancelled else { return }
                        // Canonical-key identity, not raw spellings: a foreign or stale delivery
                        // is skipped, never allowed to overwrite this target's held observation.
                        guard delivered.key == probeKey else { continue }
                        guard !Task.isCancelled else { return }
                        snapshot = delivered
                    }
                }

            if !controls.isEmpty {
                HStack(spacing: 4) {
                    ForEach(controls, id: \.kind) { control in
                        ACPModelParameterPinChip(
                            control: control,
                            providerDisplayName: providerDisplayName,
                            showsParameterName: showsParameterNames,
                            isEnabled: isEnabled,
                            onChange: onChange
                        )
                    }
                }
            }
        }
    }
}
