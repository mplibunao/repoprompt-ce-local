import AppKit
@testable import RepoPromptApp
import SwiftUI
import XCTest

/// Metadata-acquisition ownership for the Settings pin row: static metadata needs no probe, an
/// OpenCode row owns exactly one demand-scoped subscription however many chips it shows, and
/// that subscription ends on target change and teardown. The view is hosted in a window that
/// is never ordered on screen.
@MainActor
final class ACPModelParameterProbeViewTests: XCTestCase {
    private static let openCodeModelRaw = "ollama-cloud/kimi-k3"

    /// Records every subscription the injected provider hands out and every stream the view
    /// releases, standing in for `OpenCodeACPModelPollingService`.
    @MainActor
    private final class StreamRecorder {
        private(set) var subscribedKeys: [OpenCodeACPModelParameterKey] = []
        private(set) var terminatedCount = 0
        private var continuations: [AsyncStream<OpenCodeACPModelParameterSnapshot>.Continuation] = []

        func provider() -> ACPModelParameterProbeView.OpenCodeParameterStreamProvider {
            { [self] workspacePath, modelRaw in
                subscribedKeys.append(OpenCodeACPModelParameterKey(workspacePath: workspacePath, modelRaw: modelRaw))
                let (stream, continuation) = AsyncStream<OpenCodeACPModelParameterSnapshot>.makeStream()
                continuation.onTermination = { _ in
                    Task { @MainActor [weak self] in self?.terminatedCount += 1 }
                }
                continuations.append(continuation)
                return stream
            }
        }

        func finishAll() {
            continuations.forEach { $0.finish() }
        }

        func yieldToLatest(_ snapshot: OpenCodeACPModelParameterSnapshot) {
            continuations.last?.yield(snapshot)
        }
    }

    func testCursorRowResolvesStaticControlsWithoutSubscribing() async throws {
        let controls = ACPModelParameterProbeView.pinControls(
            providerID: .cursor,
            modelRaw: "grok-4.6",
            probeContext: .unavailable,
            openCodeSnapshot: nil,
            savedSelections: []
        )
        XCTAssertEqual(controls.map(\.kind), [.thinking, .speed], "Static metadata needs no workspace or session.")
        XCTAssertTrue(controls.allSatisfy { $0.definition != nil })

        let recorder = StreamRecorder()
        let host = try makeHost(probeView(providerID: .cursor, modelRaw: "grok-4.6", recorder: recorder))
        defer { host.tearDown() }
        try await settle()

        XCTAssertTrue(recorder.subscribedKeys.isEmpty, "Cursor must not open an OpenCode probe.")
    }

    func testOpenCodeRowWithSeveralControlsOwnsOneSubscription() async throws {
        let saved = [
            openCodePin(kind: .thinking, configID: "effort", valueRaw: "high"),
            openCodePin(kind: .speed, configID: "fast", valueRaw: "true")
        ]
        let recorder = StreamRecorder()
        let view = probeView(providerID: .openCode, modelRaw: Self.openCodeModelRaw, saved: saved, recorder: recorder)
        let host = try makeHost(view)
        defer { host.tearDown() }
        try await waitUntil { recorder.subscribedKeys.count == 1 }

        // A re-render with the same target keeps the existing subscription.
        host.hostingView.rootView = AnyView(view)
        try await settle()

        XCTAssertEqual(recorder.subscribedKeys, [OpenCodeACPModelParameterKey(workspacePath: "/tmp/ws", modelRaw: Self.openCodeModelRaw)])
        XCTAssertEqual(recorder.terminatedCount, 0)

        // The single observation feeds every control in the row.
        let key = try XCTUnwrap(recorder.subscribedKeys.first)
        let snapshot = OpenCodeACPModelParameterSnapshot(
            key: key,
            state: .available(ACPModelParameterSet(
                baseModelRaw: Self.openCodeModelRaw,
                parameters: [
                    ACPModelParameterTestSupport.definition(kind: .thinking, configID: "effort", values: ["low", "high"]),
                    ACPModelParameterTestSupport.definition(kind: .speed, configID: "fast", values: ["false", "true"])
                ]
            )),
            updatedAt: Date()
        )
        let controls = ACPModelParameterProbeView.pinControls(
            providerID: .openCode,
            modelRaw: Self.openCodeModelRaw,
            probeContext: .resolved("/tmp/ws"),
            openCodeSnapshot: snapshot,
            savedSelections: saved
        )
        XCTAssertEqual(controls.map(\.kind), [.thinking, .speed])
        XCTAssertTrue(controls.allSatisfy { $0.definition != nil && $0.saved != nil })
        XCTAssertTrue(ACPModelParameterProbeView.showsParameterNames(controls))
    }

    /// Only a lone OpenCode thinking chip keeps its unprefixed label.
    func testParameterNamesAreHiddenOnlyForALoneOpenCodeThinkingChip() {
        func controls(_ providerID: ACPProviderID, _ kinds: [ACPModelParameterKind]) -> [ACPModelParameterPinControl] {
            kinds.map { kind in
                ACPModelParameterPinControl(
                    providerID: providerID,
                    baseModelRaw: Self.openCodeModelRaw,
                    kind: kind,
                    definition: nil,
                    saved: nil,
                    hasParameterSet: false
                )
            }
        }
        XCTAssertFalse(ACPModelParameterProbeView.showsParameterNames(controls(.openCode, [.thinking])))
        XCTAssertTrue(ACPModelParameterProbeView.showsParameterNames(controls(.openCode, [.speed])))
        XCTAssertTrue(ACPModelParameterProbeView.showsParameterNames(controls(.openCode, [.thinking, .speed])))
        XCTAssertTrue(ACPModelParameterProbeView.showsParameterNames(controls(.cursor, [.thinking])))
        XCTAssertTrue(ACPModelParameterProbeView.showsParameterNames(controls(.cursor, [.speed])))
    }

    /// The models popover's role row for an OpenCode model starts with no chips and gains two once
    /// metadata arrives. The row's layout must not depend on the chips it shows: a layout switch
    /// would give the pin row a new identity, restarting discovery with no snapshot, which
    /// removes the chips and switches back, over and over.
    func testPopoverRoleRowKeepsOneSubscriptionWhenChipsAppear() async throws {
        let recorder = StreamRecorder()
        let row = AgentModelsRoleRowLayout(showsParameterPins: true) {
            Text("Engineer").frame(width: 64, alignment: .leading)
        } modelPicker: {
            Text("OpenCode · Kimi K3 with a long display name").lineLimit(1)
        } parameterPins: {
            self.probeView(providerID: .openCode, modelRaw: Self.openCodeModelRaw, recorder: recorder)
        }
        let host = try makeHost(row, width: 300)
        defer {
            host.tearDown()
            recorder.finishAll()
        }
        try await waitUntil { recorder.subscribedKeys.count == 1 }
        let heightWithoutChips = host.hostingView.fittingSize.height

        let key = try XCTUnwrap(recorder.subscribedKeys.first)
        recorder.yieldToLatest(OpenCodeACPModelParameterSnapshot(
            key: key,
            state: .available(ACPModelParameterSet(
                baseModelRaw: Self.openCodeModelRaw,
                parameters: [
                    ACPModelParameterTestSupport.definition(kind: .thinking, configID: "effort", values: ["low", "high"]),
                    ACPModelParameterTestSupport.definition(kind: .speed, configID: "fast", values: ["false", "true"])
                ]
            )),
            updatedAt: Date()
        ))
        try await waitUntil { host.hostingView.fittingSize.height > heightWithoutChips }
        try await Task.sleep(for: .seconds(1))

        XCTAssertEqual(recorder.subscribedKeys.count, 1, "Chips appearing must not restart discovery.")
        XCTAssertEqual(recorder.terminatedCount, 0)
        XCTAssertGreaterThan(host.hostingView.fittingSize.height, heightWithoutChips, "The chips stay shown.")
    }

    func testSubscriptionEndsOnTargetChangeAndTeardown() async throws {
        let recorder = StreamRecorder()
        let host = try makeHost(probeView(providerID: .openCode, modelRaw: Self.openCodeModelRaw, recorder: recorder))
        try await waitUntil { recorder.subscribedKeys.count == 1 }

        host.hostingView.rootView = AnyView(
            probeView(providerID: .openCode, modelRaw: "ollama-cloud/glm-5.3", recorder: recorder)
        )
        try await waitUntil { recorder.subscribedKeys.count == 2 && recorder.terminatedCount == 1 }
        XCTAssertEqual(
            recorder.subscribedKeys.last,
            OpenCodeACPModelParameterKey(workspacePath: "/tmp/ws", modelRaw: "ollama-cloud/glm-5.3")
        )

        host.tearDown()
        try await waitUntil { recorder.terminatedCount == 2 }
        recorder.finishAll()
    }

    func testUnavailableProbeContextNeverSubscribesOrBecomesNilWorkspace() async throws {
        let pin = openCodePin(kind: .thinking, configID: "effort", valueRaw: "high")
        let nilWorkspaceSnapshot = OpenCodeACPModelParameterSnapshot(
            key: OpenCodeACPModelParameterKey(workspacePath: nil, modelRaw: Self.openCodeModelRaw),
            state: .available(ACPModelParameterSet(
                baseModelRaw: Self.openCodeModelRaw,
                parameters: [ACPModelParameterTestSupport.definition(kind: .thinking, configID: "effort", values: ["low", "high"])]
            )),
            updatedAt: Date()
        )
        let controls = ACPModelParameterProbeView.pinControls(
            providerID: .openCode,
            modelRaw: Self.openCodeModelRaw,
            probeContext: .unavailable,
            openCodeSnapshot: nilWorkspaceSnapshot,
            savedSelections: [pin]
        )
        XCTAssertEqual(controls.count, 1)
        XCTAssertNil(controls[0].definition, "An unresolved workspace must not borrow the nil-workspace observation.")
        XCTAssertEqual(controls[0].saved, pin)
        XCTAssertFalse(ACPModelParameterProbeView.showsParameterNames(controls))

        let recorder = StreamRecorder()
        let host = try makeHost(probeView(
            providerID: .openCode,
            modelRaw: Self.openCodeModelRaw,
            probeContext: .unavailable,
            saved: [pin],
            recorder: recorder
        ))
        defer { host.tearDown() }
        try await settle()
        XCTAssertTrue(recorder.subscribedKeys.isEmpty)
    }

    // MARK: - Hosting

    @MainActor
    private struct Host {
        let window: NSWindow
        let hostingView: NSHostingView<AnyView>

        func tearDown() {
            window.contentView = nil
            window.close()
        }
    }

    private func makeHost(_ view: some View, width: CGFloat = 400) throws -> Host {
        let hostingView = NSHostingView(rootView: AnyView(view))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 60),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()
        return Host(window: window, hostingView: hostingView)
    }

    private func probeView(
        providerID: ACPProviderID,
        modelRaw: String,
        probeContext: ACPModelParameterProbeContext = .resolved("/tmp/ws"),
        saved: [ACPModelParameterSelection] = [],
        recorder: StreamRecorder
    ) -> ACPModelParameterProbeView {
        ACPModelParameterProbeView(
            modelRaw: modelRaw,
            providerID: providerID,
            providerDisplayName: providerID == .cursor ? "Cursor CLI" : "OpenCode",
            probeContext: probeContext,
            savedSelections: saved,
            openCodeStreamProvider: recorder.provider(),
            onChange: { _ in XCTFail("Hosting and metadata arrival must never write settings.") }
        )
    }

    /// Lets SwiftUI schedule and run any pending `.task` work.
    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(200))
    }

    private func waitUntil(
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                return XCTFail("Condition not met within \(timeout)s.", file: file, line: line)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: - Fixtures

    private func openCodePin(
        kind: ACPModelParameterKind,
        configID: String,
        valueRaw: String
    ) -> ACPModelParameterSelection {
        ACPModelParameterSelection(
            providerID: .openCode,
            baseModelRaw: Self.openCodeModelRaw,
            kind: kind,
            configID: configID,
            valueRaw: valueRaw
        )
    }
}
