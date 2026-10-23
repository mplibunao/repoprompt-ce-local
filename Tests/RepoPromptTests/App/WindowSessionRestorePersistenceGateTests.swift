@testable import RepoPromptApp
import XCTest

/// Regression coverage for the crash-relaunch session clobber:
/// `windowSessions.json` writes requested while the startup restore session is
/// still loading or applying must be deferred, not written, so a crash-surviving
/// snapshot (and the workspace whose agent/oracle settings it points at) is not
/// overwritten by the transient default/system-workspace startup state.
final class WindowSessionRestorePersistenceGateTests: XCTestCase {
    func testIdleGateAllowsImmediatePersistAndHasNothingToFlush() {
        var gate = WindowSessionRestorePersistenceGate()

        XCTAssertFalse(gate.isRestoreInProgress)
        XCTAssertTrue(gate.shouldPersistNow(reason: "registerWindow"))
        XCTAssertNil(gate.deferredPersistReason)
        XCTAssertNil(gate.takeFlushableDeferredReason())
    }

    func testPersistRequestsDuringSessionLoadAreDeferredUntilLoadFinishes() {
        var gate = WindowSessionRestorePersistenceGate()
        gate.beginRestoreSessionLoad()

        XCTAssertTrue(gate.isRestoreInProgress)
        XCTAssertFalse(gate.shouldPersistNow(reason: "registerWindow"))
        XCTAssertFalse(gate.shouldPersistNow(reason: "focusChanged:true"))
        // Latest deferred reason wins; the flush recaptures current state anyway.
        XCTAssertEqual(gate.deferredPersistReason, "focusChanged:true")
        // Still loading: nothing may flush yet.
        XCTAssertNil(gate.takeFlushableDeferredReason())

        gate.finishRestoreSessionLoad()

        XCTAssertFalse(gate.isRestoreInProgress)
        XCTAssertEqual(gate.takeFlushableDeferredReason(), "focusChanged:true")
        // The deferred request is consumed exactly once.
        XCTAssertNil(gate.takeFlushableDeferredReason())
    }

    func testPersistRequestsDeferredWhileAnyWindowRestoreIsInFlight() {
        var gate = WindowSessionRestorePersistenceGate()
        gate.beginRestoreSessionLoad()
        gate.finishRestoreSessionLoad()

        // Both entries are handed to their registered windows.
        gate.beginRestoringWindow(1)
        gate.beginRestoringWindow(2)

        // Load finished but two windows are still applying their restore entries.
        XCTAssertTrue(gate.isRestoreInProgress)
        XCTAssertFalse(gate.shouldPersistNow(reason: "workspaceSwitch"))
        XCTAssertNil(gate.takeFlushableDeferredReason())

        gate.finishRestoringWindow(1)
        XCTAssertTrue(gate.isRestoreInProgress)
        XCTAssertNil(gate.takeFlushableDeferredReason())

        gate.finishRestoringWindow(2)
        XCTAssertFalse(gate.isRestoreInProgress)
        XCTAssertEqual(gate.takeFlushableDeferredReason(), "workspaceSwitch")
    }

    func testWindowClosedMidRestoreReleasesGateAndUnknownWindowFinishIsHarmless() {
        var gate = WindowSessionRestorePersistenceGate()
        gate.beginRestoringWindow(7)
        XCTAssertFalse(gate.shouldPersistNow(reason: "unregisterWindow:7"))

        // Unregistering a window mid-restore must not leave the gate held forever.
        gate.finishRestoringWindow(7)
        XCTAssertFalse(gate.isRestoreInProgress)
        XCTAssertEqual(gate.takeFlushableDeferredReason(), "unregisterWindow:7")

        // Finishing a window that never began restoring stays inert.
        gate.finishRestoringWindow(42)
        XCTAssertFalse(gate.isRestoreInProgress)
        XCTAssertNil(gate.takeFlushableDeferredReason())
        XCTAssertTrue(gate.shouldPersistNow(reason: "focusChanged:false"))
    }

    func testCrashRelaunchSequenceNeverAllowsPersistBeforeRestoreCompletes() {
        var gate = WindowSessionRestorePersistenceGate()

        // 1. App init kicks off the async session load before any window registers.
        gate.beginRestoreSessionLoad()

        // 2. First window registers while the load is still pending; its snapshot
        //    would capture the default/system workspace and clobber the crash snapshot.
        XCTAssertFalse(gate.shouldPersistNow(reason: "registerWindow"))

        // 3. Load completes and the entry is handed to the window.
        gate.finishRestoreSessionLoad()
        gate.beginRestoringWindow(1)
        XCTAssertTrue(gate.isRestoreInProgress)

        // 4. Startup noise (focus, initial workspace activation) keeps deferring.
        XCTAssertFalse(gate.shouldPersistNow(reason: "focusChanged:true"))

        // 5. Restore finishes; only now may a snapshot be written.
        gate.finishRestoringWindow(1)
        XCTAssertFalse(gate.isRestoreInProgress)
        XCTAssertEqual(gate.takeFlushableDeferredReason(), "focusChanged:true")
        XCTAssertTrue(gate.shouldPersistNow(reason: "workspaceSwitch"))
    }
}
