import AppKit
import Combine
@testable import RepoPromptApp
import XCTest

@MainActor
final class WindowPresentationVisibilityLifecycleTests: XCTestCase {
    func testVisibilityFollowsAttachedWindowAndStopsAtClose() async {
        _ = NSApplication.shared
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        defer { GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false) }

        let state = WindowState()
        let firstWindow = makeTestWindow()
        let secondWindow = makeTestWindow()
        let unrelatedWindow = makeTestWindow()
        defer {
            state.beginClose()
            firstWindow.close()
            secondWindow.close()
            unrelatedWindow.close()
        }

        var publications: [Bool] = []
        let observation = state.$isPresentationVisible.dropFirst().sink { publications.append($0) }
        defer { observation.cancel() }

        XCTAssertTrue(state.isPresentationVisible, "Unattached hosts retain presentation")
        state.attachWindow(firstWindow)
        XCTAssertTrue(publications.isEmpty, "Attachment must not publish synchronously")
        await state.test_waitForPendingPresentationVisibilityUpdate()
        XCTAssertFalse(state.isPresentationVisible, "An unordered window is not visible")
        XCTAssertEqual(publications, [false])

        state.attachWindow(firstWindow)
        await state.test_waitForPendingPresentationVisibilityUpdate()
        XCTAssertEqual(publications, [false], "Same-window attachment does not republish equal state")

        state.attachWindow(firstWindow)
        state.attachWindow(secondWindow)
        state.attachWindow(nil)
        await drainNotificationDelivery()
        await state.test_waitForPendingPresentationVisibilityUpdate()
        XCTAssertTrue(state.isPresentationVisible, "Only the latest detached sample may publish")
        XCTAssertEqual(publications, [false, true])

        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: firstWindow)
        NotificationCenter.default.post(name: NSWindow.didMiniaturizeNotification, object: unrelatedWindow)
        await drainNotificationDelivery()
        await state.test_waitForPendingPresentationVisibilityUpdate()
        XCTAssertEqual(publications, [false, true], "Detached and unrelated windows cannot publish")

        state.attachWindow(secondWindow)
        await state.test_waitForPendingPresentationVisibilityUpdate()
        XCTAssertFalse(state.isPresentationVisible)
        state.attachWindow(nil)
        state.attachWindow(secondWindow)
        await drainNotificationDelivery()
        await state.test_waitForPendingPresentationVisibilityUpdate()
        XCTAssertEqual(publications, [false, true, false], "A stale detach must not restore true after reattachment")

        state.attachWindow(nil)
        state.beginClose()
        NotificationCenter.default.post(name: NSApplication.didUnhideNotification, object: NSApp)
        NotificationCenter.default.post(name: NSWindow.didDeminiaturizeNotification, object: secondWindow)
        await drainNotificationDelivery()
        await state.test_waitForPendingPresentationVisibilityUpdate()
        XCTAssertFalse(state.isPresentationVisible, "Close cancels the pending detached sample")
        XCTAssertEqual(publications, [false, true, false], "Close and later notifications publish nothing")

        await state.tearDown()
    }

    private func drainNotificationDelivery() async {
        await withCheckedContinuation { continuation in
            RunLoop.main.perform { continuation.resume() }
        }
    }

    private func makeTestWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        return window
    }
}
