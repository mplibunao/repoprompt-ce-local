import Foundation
@testable import RepoPromptApp
import XCTest

final class AgentContextExportSourceBuilderTests: XCTestCase {
    func testSelectionResolutionPreservesSourcePrecedence() {
        let requestedTabID = UUID()
        let activeTabID = UUID()
        let missingTabID = UUID()
        let snapshotSelection = StoredSelection(
            selectedPaths: ["snapshot.swift"],
            manualCodemapPaths: ["outline.swift"],
            codemapAutoEnabled: false
        )
        let storedSelection = StoredSelection(selectedPaths: ["stored.swift"])
        let activeSelection = StoredSelection(selectedPaths: ["active.swift"])
        let tabs = [
            ComposeTabState(id: requestedTabID, selection: storedSelection),
            ComposeTabState(id: activeTabID, selection: activeSelection)
        ]
        typealias Row = (
            label: String,
            requestedTabID: UUID?,
            activeTabID: UUID?,
            snapshot: WorkspaceSelectionCoordinator.Snapshot?,
            expectedTabID: UUID?,
            expectedSelection: StoredSelection
        )
        let rows: [Row] = [
            (
                "matching snapshot overrides stored selection", requestedTabID, activeTabID,
                .init(tabID: requestedTabID, selection: snapshotSelection, isVirtual: false),
                requestedTabID, snapshotSelection
            ),
            (
                "mismatched snapshot uses requested tab", requestedTabID, activeTabID,
                .init(tabID: activeTabID, selection: snapshotSelection, isVirtual: false),
                requestedTabID, storedSelection
            ),
            (
                "stored compose-tab selection without snapshot", requestedTabID, activeTabID, nil,
                requestedTabID, storedSelection
            ),
            (
                "snapshot tab precedes active tab", nil, activeTabID,
                .init(tabID: requestedTabID, selection: snapshotSelection, isVirtual: true),
                requestedTabID, snapshotSelection
            ),
            ("active-tab fallback", nil, activeTabID, nil, activeTabID, activeSelection),
            (
                "missing requested tab does not fall back", missingTabID, activeTabID,
                .init(tabID: activeTabID, selection: snapshotSelection, isVirtual: false),
                missingTabID, StoredSelection()
            ),
            ("no tab", nil, nil, nil, nil, StoredSelection()),
            (
                "nil snapshot tab matches nil resolved tab", nil, nil,
                .init(tabID: nil, selection: snapshotSelection, isVirtual: true),
                nil, snapshotSelection
            )
        ]

        for row in rows {
            let resolved = AgentContextExportSourceBuilder.resolveSelection(
                requestedTabID: row.requestedTabID,
                activeComposeTabID: row.activeTabID,
                selectionSnapshot: row.snapshot,
                composeTabs: tabs
            )
            let source = AgentContextExportSourceBuilder.makeSource(
                AgentContextExportSourceBuildRequest(
                    requestedTabID: row.requestedTabID,
                    activeComposeTabID: row.activeTabID,
                    activePromptText: "",
                    selectionSnapshot: row.snapshot,
                    composeTabs: tabs,
                    explicitActiveAgentSessionID: nil,
                    worktreeBindingsProvider: { _, _ in [] }
                )
            )

            XCTAssertEqual(resolved.tabID, row.expectedTabID, row.label)
            XCTAssertEqual(resolved.selection, row.expectedSelection, row.label)
            XCTAssertEqual(source.tabID, row.expectedTabID, row.label)
            XCTAssertEqual(source.selection, row.expectedSelection, row.label)
        }
    }
}
