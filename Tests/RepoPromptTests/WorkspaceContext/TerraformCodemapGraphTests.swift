import Foundation
@testable import RepoPromptApp
import RepoPromptCodeMapCore
import XCTest

/// The folder-qualified Terraform graph, driven with synthetic `tf1` contributions. The harness's
/// assertions run on the main actor because XCTest can drop an off-main assertion failure that it
/// hasn't recorded by the time an async test returns.
final class TerraformCodemapGraphTests: XCTestCase {
    private typealias Definition = TerraformCodeMapGraphNames.Definition
    private typealias Reference = TerraformCodeMapGraphNames.Reference

    // MARK: - Required edges

    @MainActor
    func testScopedLinksMatchRequiredEdgeTable() async throws {
        let harness = try await CodemapGraphIndexHarness(seed: 0xC1)
        let slots = try Self.demoLayout(harness) + [
            // A decoy module and a nested folder declare the same input and output names as the child.
            harness.terraformSlot(
                10,
                "modules/decoy/variables.tf",
                definitions: [.variable(name: "project_id"), .output(name: "endpoint")]
            ),
            harness.terraformSlot(
                11,
                "modules/worker/nested/main.tf",
                definitions: [.variable(name: "project_id"), .output(name: "endpoint")]
            ),
            // A slash followed by a combining mark is one `Character`. The file still sits directly
            // in the child folder.
            harness.terraformSlot(13, "modules/worker/\u{301}locals.tf", references: [.variable(name: "project_id")])
        ]
        try await harness.publishComplete(slots)

        let snapshot = try await harness.latestSnapshot()
        XCTAssertEqual(Self.edgeRows(snapshot), [
            // The folder link targets each file directly in the child folder and is ambiguous on its
            // own. The unique input makes the edge to `variables.tf` unambiguous.
            EdgeRow("projects/demo/compute.tf", "modules/worker/main.tf", [Evidence.workerSource], 4),
            EdgeRow("projects/demo/compute.tf", "modules/worker/outputs.tf", [Evidence.workerSource], 4),
            EdgeRow("projects/demo/compute.tf", "modules/worker/\u{301}locals.tf", [Evidence.workerSource], 4),
            EdgeRow(
                "projects/demo/compute.tf",
                "modules/worker/variables.tf",
                [Evidence.workerInput, Evidence.workerSource],
                1
            ),
            EdgeRow("projects/demo/outputs.tf", "projects/demo/compute.tf", [Evidence.workerCall], 1),
            // The output link is direct, not reached through the call file.
            EdgeRow("projects/demo/outputs.tf", "modules/worker/outputs.tf", [Evidence.workerOutput], 1),
            EdgeRow("modules/worker/main.tf", "modules/worker/variables.tf", [Evidence.childVariable], 1),
            EdgeRow("modules/worker/\u{301}locals.tf", "modules/worker/variables.tf", [Evidence.childVariable], 1),
            EdgeRow("modules/worker/outputs.tf", "modules/worker/main.tf", [Evidence.childResource], 1)
        ])
        XCTAssertTrue(snapshot.unresolvedBySource.isEmpty)
    }

    // MARK: - Binding states

    @MainActor
    func testCallBindingStatesYieldExactUnresolvedReasons() async throws {
        enum CallChange {
            case source(TerraformModuleSource)
            case repeatedInCallFile
            case declaredInSecondFile
            case pending
            case deleted
        }
        func withheld(_ reason: WorkspaceCodemapGraphUnresolvedReason) -> Set<UnresolvedRow> {
            [
                UnresolvedRow("projects/demo/compute.tf", Evidence.workerSourceWithheld, reason),
                UnresolvedRow("projects/demo/compute.tf", Evidence.workerInputWithheld, reason),
                UnresolvedRow("projects/demo/outputs.tf", Evidence.workerOutputWithheld, reason)
            ]
        }
        let rows: [(label: String, change: CallChange, candidateThreshold: UInt64?, expected: Set<UnresolvedRow>)] = [
            ("label repeated in the call file", .repeatedInCallFile, nil, withheld(.ambiguousModuleCall)),
            ("label declared in a second file", .declaredInSecondFile, nil, withheld(.ambiguousModuleCall)),
            ("declarations above the candidate threshold", .declaredInSecondFile, 1, withheld(.tooCommon)),
            (
                "call file pending",
                .pending,
                nil,
                [UnresolvedRow("projects/demo/outputs.tf", Evidence.workerOutputWithheld, .notIndexedYet)]
            ),
            (
                "call file deleted",
                .deleted,
                nil,
                [UnresolvedRow("projects/demo/outputs.tf", Evidence.workerOutputWithheld, .missing)]
            ),
            ("computed source", .source(.nonLiteral), nil, withheld(.unsupportedModuleSource)),
            ("registry source", .source(.literal("example/worker/aws")), nil, withheld(.unsupportedModuleSource)),
            // Each of these resolves to the indexed child folder if a resolver strips its prefix.
            (
                "absolute source",
                .source(.literal("/workspace/modules/worker")),
                nil,
                withheld(.unsupportedModuleSource)
            ),
            (
                "source escaping the loaded root",
                .source(.literal("../../../modules/worker")),
                nil,
                withheld(.outsideLoadedRoot)
            ),
            ("empty source", .source(.literal("")), nil, withheld(.invalidModuleCall)),
            ("missing source", .source(.missing), nil, withheld(.invalidModuleCall)),
            ("malformed source", .source(.invalid), nil, withheld(.invalidModuleCall)),
            ("source containing NUL", .source(.literal("../../modules/\u{0}worker")), nil, withheld(.invalidModuleCall))
        ]

        for row in rows {
            let policy = try row.candidateThreshold.map { threshold in
                let size = WorkspaceCodemapSelectionGraphSizePolicy.initial
                return try XCTUnwrap(WorkspaceCodemapGraphPolicy(
                    candidateOverflowThreshold: threshold,
                    graphSizePolicy: WorkspaceCodemapSelectionGraphSizePolicy(
                        maxNodes: size.maxNodes,
                        maxPostings: size.maxPostings,
                        maxEdges: size.maxEdges,
                        maxBytes: size.maxBytes,
                        maxDefinitionCandidates: threshold
                    )
                ), row.label)
            } ?? .initial
            let harness = try await CodemapGraphIndexHarness(seed: 0xC2, graphPolicy: policy)
            var layout = try Self.demoLayout(harness)
            if case .declaredInSecondFile = row.change {
                // A graph-index publication can't add a file, so the second declaration moves in.
                try layout.append(Self.secondCallFile(harness, path: "projects/elsewhere/extra.tf", generation: 1))
            }
            try await harness.publishComplete(layout)
            let before = try await Self.edgeRows(harness.latestSnapshot())
            XCTAssertTrue(
                before.contains { $0.source == "projects/demo/compute.tf" && $0.target == "modules/worker/variables.tf" },
                "\(row.label): the valid call links its input before the change"
            )

            switch row.change {
            case let .source(source):
                try await harness.publishCommitted([Self.callFile(harness, source: source, generation: 2)], row.label)
            case .repeatedInCallFile:
                try await harness.publishCommitted([harness.terraformSlot(
                    0,
                    "projects/demo/compute.tf",
                    definitions: [.call(name: "worker", source: Self.workerSource), .callDuplicate(name: "worker")],
                    references: [.childFolder(call: "worker"), .childInput(call: "worker", argument: "project_id")],
                    generation: 2
                )], row.label)
            case .declaredInSecondFile:
                try await harness.publishCommitted(
                    [Self.secondCallFile(harness, path: "projects/demo/extra.tf", generation: 2)],
                    row.label
                )
            case .pending:
                try await harness.publishCommitted([harness.makeSlot(
                    fileID: harness.fileID(0, lane: Self.lane),
                    path: "projects/demo/compute.tf",
                    state: .pending,
                    requestGeneration: 2,
                    pathGeneration: 2,
                    language: .terraform
                )], row.label)
            case .deleted:
                // Deletion reaches the graph when a reconciliation pass doesn't see the file again.
                let began = await harness.overlay.beginGraphReconciliation(rootEpoch: harness.rootEpoch)
                XCTAssertTrue(began, row.label)
                let survivors = await harness.publish(layout.filter { $0.fileID != Self.callFileID(harness) })
                XCTAssertTrue(survivors, row.label)
                try await harness.publishCommitted([], row.label)
            }

            let snapshot = try await harness.latestSnapshot()
            let childEdges = Self.edgeRows(snapshot).filter {
                $0.source.hasPrefix("projects/demo/") && $0.target.hasPrefix("modules/")
            }
            XCTAssertEqual(childEdges, [], row.label)
            let childRecords = Self.unresolvedRows(snapshot).filter {
                ["projects/demo/compute.tf", "projects/demo/outputs.tf"].contains($0.source) &&
                    $0.name.hasPrefix(Evidence.workerCall + " ")
            }
            XCTAssertEqual(childRecords, row.expected, row.label)
        }
    }

    // MARK: - Reprojection

    @MainActor
    func testCallSourceChangesReprojectUnchangedConsumers() async throws {
        let harness = try await CodemapGraphIndexHarness(seed: 0xC3)
        let outputsID = harness.fileID(1, lane: Self.lane)
        let slots = try Self.demoLayout(harness, source: .literal("../../modules/worker")) + [
            harness.terraformSlot(12, "modules/other/outputs.tf", definitions: [.output(name: "endpoint")])
        ]
        try await harness.publishComplete(slots)
        let before = try await harness.latestSnapshot()
        XCTAssertEqual(Self.outputTargets(before, sourceID: outputsID), ["modules/worker/outputs.tf"])

        let disposition = try await harness.publishCommitted([
            Self.callFile(harness, source: .literal("../../modules/other"), generation: 2)
        ])
        guard case .committed(_, _, changedFileCount: 1, _, resync: false) = disposition else {
            return XCTFail("Only the call file changes, got \(disposition)")
        }
        let after = try await harness.latestSnapshot()
        XCTAssertEqual(after.slotsByFileID[outputsID], before.slotsByFileID[outputsID])
        XCTAssertEqual(Self.outputTargets(after, sourceID: outputsID), ["modules/other/outputs.tf"])
    }

    @MainActor
    func testIncrementalGraphMatchesRebuildAcrossMoves() async throws {
        let incremental = try await CodemapGraphIndexHarness(seed: 0xC4, mode: .incremental)
        let full = try await CodemapGraphIndexHarness(seed: 0xC4, mode: .alwaysFull)
        let initial = try Self.demoLayout(incremental) + [
            incremental.terraformSlot(12, "modules/other/outputs.tf", definitions: [.output(name: "endpoint")])
        ]
        var current = Dictionary(uniqueKeysWithValues: initial.map { ($0.fileID, $0) })
        func step(_ label: String, _ slots: [WorkspaceCodemapGraphSlot]) async throws {
            for slot in slots {
                current[slot.fileID] = slot
            }
            for harness in [incremental, full] {
                let published = await harness.publish(
                    slots,
                    projectedTotal: UInt64(current.count),
                    enumerationFinished: true
                )
                XCTAssertTrue(published, label)
                _ = await harness.pull()
            }
            try await assertParity(incremental, full, step: label, expectCheckpoint: true)
        }

        let source = Definition.call(name: "worker", source: Self.workerSource)
        let callReferences: [Reference] = [.childFolder(call: "worker"), .childInput(call: "worker", argument: "project_id")]
        let consumerReferences: [Reference] = [.call(name: "worker"), .childOutput(call: "worker", output: "endpoint")]
        try await step("initial", initial)
        try await step("rename the call file within its folder", [incremental.terraformSlot(
            0, "projects/demo/calls.tf", definitions: [source], references: callReferences, generation: 2
        )])
        try await step("move the consumer to another folder", [incremental.terraformSlot(
            1, "projects/other/outputs.tf", references: consumerReferences, generation: 2
        )])
        try await step("move the call file after it", [incremental.terraformSlot(
            0, "projects/other/calls.tf", definitions: [source], references: callReferences, generation: 3
        )])
        let moved = try await incremental.latestSnapshot()
        XCTAssertEqual(
            Self.outputTargets(moved, sourceID: incremental.fileID(1, lane: Self.lane)),
            ["modules/worker/outputs.tf"],
            "The consumer binds through the call in its new folder"
        )
        try await step("move the child folder", [
            incremental.terraformSlot(
                2,
                "modules/moved/main.tf",
                definitions: [.resource(type: "null_resource", name: "worker")],
                references: [.variable(name: "project_id")],
                generation: 2
            ),
            incremental.terraformSlot(
                3,
                "modules/moved/variables.tf",
                definitions: [.variable(name: "project_id")],
                generation: 2
            ),
            incremental.terraformSlot(
                4,
                "modules/moved/outputs.tf",
                definitions: [.output(name: "endpoint")],
                references: [.resource(type: "null_resource", name: "worker")],
                generation: 2
            )
        ])
        let movedSource = Definition.call(name: "worker", source: .literal("../../modules/moved"))
        try await step("point the call at the moved folder", [incremental.terraformSlot(
            0, "projects/other/calls.tf", definitions: [movedSource], references: callReferences, generation: 4
        )])
        // String equality treats the two spellings as one folder, so the republish doesn't change any
        // call key.
        try await step("move the call file to a composed folder name", [incremental.terraformSlot(
            0, "projects/caf\u{E9}/calls.tf", definitions: [movedSource], references: callReferences, generation: 5
        )])
        try await step("republish it under the decomposed spelling", [incremental.terraformSlot(
            0, "projects/cafe\u{301}/calls.tf", definitions: [movedSource], references: callReferences, generation: 6
        )])

        // Deletion reaches the graph when a reconciliation pass doesn't see the file again.
        let callID = incremental.fileID(0, lane: Self.lane)
        current.removeValue(forKey: callID)
        for harness in [incremental, full] {
            let began = await harness.overlay.beginGraphReconciliation(rootEpoch: harness.rootEpoch)
            XCTAssertTrue(began)
            let survivors = await harness.publish(Array(current.values))
            XCTAssertTrue(survivors)
            _ = await harness.pull()
            let finished = await harness.publish([], enumerationFinished: true)
            XCTAssertTrue(finished)
            _ = await harness.pull()
        }
        try await assertParity(incremental, full, step: "delete the call file", expectCheckpoint: true)
    }

    // MARK: - Fences

    @MainActor
    func testModuleDependencyFencesProtectQueriesAndReceipts() async throws {
        let gate = CodemapGraphIndexGate()
        let harness = try await CodemapGraphIndexHarness(seed: 0xC6, gate: gate)
        let callID = harness.fileID(0, lane: Self.lane)
        let outputsID = harness.fileID(1, lane: Self.lane)
        let childOutputsID = harness.fileID(4, lane: Self.lane)
        let consumerReferences: [Reference] = [.call(name: "worker"), .childOutput(call: "worker", output: "endpoint")]
        let slots = try Self.demoLayout(harness) + [
            harness.terraformSlot(12, "modules/other/outputs.tf", definitions: [.output(name: "endpoint")]),
            // A graph-index publication can't add a file, so this subscriber moves in later.
            harness.terraformSlot(21, "projects/late/late.tf", references: consumerReferences),
            // A second stack, whose call file turns pending and then ready while a fence waits.
            Self.callFile(harness, index: 30, path: "projects/gated/compute.tf", source: Self.workerSource, generation: 1),
            harness.terraformSlot(31, "projects/gated/outputs.tf", references: consumerReferences)
        ]
        try await harness.publishComplete(slots)
        let referrersBefore = try await harness.structure(seed: childOutputsID, direction: .referrers)
        XCTAssertTrue(referrersBefore.nodes.contains { $0.fileID == outputsID })
        let receipt = try XCTUnwrap(referrersBefore.receipt)

        // Publishing the call file under a new name fences it before the graph commits the rename.
        let renamed = try Self.callFile(
            harness,
            path: "projects/demo/calls.tf",
            source: .literal("../../modules/other"),
            generation: 2
        )
        let published = await harness.publish([renamed], enumerationFinished: true)
        XCTAssertTrue(published)

        let uses = try await harness.structure(seed: outputsID, direction: .referencedDefinitions)
        XCTAssertEqual(uses.seeds.map(\.state), [.notIndexed])
        XCTAssertTrue(uses.issues.contains(.seedFenced(outputsID)))
        XCTAssertEqual(uses.edges, [])
        let usedBy = try await harness.structure(seed: outputsID, direction: .referrers)
        XCTAssertTrue(usedBy.issues.contains(.seedFenced(outputsID)))
        let referrers = try await harness.structure(seed: childOutputsID, direction: .referrers)
        XCTAssertFalse(referrers.nodes.contains { $0.fileID == outputsID })
        let auto = try await harness.automaticSelection(source: outputsID)
        XCTAssertEqual(auto.sources.map(\.state), [.fenced])
        XCTAssertEqual(auto.targets, [])
        let dependentReceipt = await harness.graph.revalidate(receipt, affectedFileIDs: [outputsID])
        XCTAssertEqual(dependentReceipt, .invalid(.fencedFileOverlap))
        let unrelatedReceipt = await harness.graph.revalidate(receipt, affectedFileIDs: [childOutputsID])
        guard case .valid = unrelatedReceipt else {
            return XCTFail("A receipt that names no fenced file stays valid, got \(unrelatedReceipt)")
        }

        // The commit that renames the call file reprojects the dependent, which is then unfenced.
        let committed = await harness.pull()
        guard case .committed = committed else { return XCTFail("The rename must commit, got \(String(describing: committed))") }
        let fresh = try await harness.automaticSelection(source: outputsID)
        XCTAssertEqual(fresh.sources.map(\.state), [.covered])
        XCTAssertEqual(fresh.targets.map(\.standardizedRelativePath), ["modules/other/outputs.tf", "projects/demo/calls.tf"])

        // A commit that subscribes a file to a call whose file is still fenced fences that file too.
        // The move's own fence names the file's old slot, so it lapses with this commit.
        let fenced = await harness.graph.fenceFiles(fileIDs: [callID], reason: .deleted)
        guard case .fenced = fenced else { return XCTFail("The call file must fence, got \(fenced)") }
        let lateID = harness.fileID(21, lane: Self.lane)
        try await harness.publishCommitted([
            harness.terraformSlot(21, "projects/demo/late.tf", references: consumerReferences, generation: 2)
        ])
        let late = try await harness.automaticSelection(source: lateID)
        XCTAssertEqual(late.sources.map(\.state), [.fenced])
        XCTAssertEqual(late.targets, [])

        // A pending call file that turns ready keeps its request and path generations, so a deletion
        // fence taken while the apply waits still matches it. The consumer the declaration resolves
        // is already subscribed, and must stay fenced once the commit gives it the child's output.
        let gatedCallID = harness.fileID(30, lane: Self.lane)
        let gatedOutputsID = harness.fileID(31, lane: Self.lane)
        try await harness.publishCommitted([harness.makeSlot(
            fileID: gatedCallID,
            path: "projects/gated/compute.tf",
            state: .pending,
            requestGeneration: 2,
            pathGeneration: 2,
            language: .terraform
        )])
        await gate.close()
        let ready = try Self.callFile(
            harness,
            index: 30,
            path: "projects/gated/compute.tf",
            source: Self.workerSource,
            generation: 2
        )
        let publishedReady = await harness.publish([ready], enumerationFinished: true)
        XCTAssertTrue(publishedReady)
        let apply = Task { await harness.pull() }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while await gate.waiterCount == 0, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let waiterCount = await gate.waiterCount
        XCTAssertEqual(waiterCount, 1)
        let gatedFence = await harness.graph.fenceFiles(fileIDs: [gatedCallID], reason: .deleted)
        await gate.open()
        guard case .fenced = gatedFence else { return XCTFail("The pending call file must fence, got \(gatedFence)") }
        let readyCommit = await apply.value
        guard case .committed = readyCommit else {
            return XCTFail("The ready call file must commit, got \(String(describing: readyCommit))")
        }
        let resolved = try await harness.latestSnapshot()
        XCTAssertEqual(Self.outputTargets(resolved, sourceID: gatedOutputsID), ["modules/worker/outputs.tf"])
        let gated = try await harness.automaticSelection(source: gatedOutputsID)
        XCTAssertEqual(gated.sources.map(\.state), [.fenced])
        XCTAssertEqual(gated.targets, [])

        // A dependent counts once against the fence capacity, however many of the parent's calls it
        // reads, and the parent's reference to its own child folder doesn't count. Fencing that fills
        // the capacity exactly succeeds. One entry more revokes the graph.
        let readsBoth: [Reference] = [
            .childOutput(call: "a", output: "endpoint"),
            .childOutput(call: "b", output: "endpoint")
        ]
        for (capacity, expected) in [
            (3, WorkspaceCodemapGraphFenceDisposition.fenced(safetyCounter: 1)),
            (2, .revoked(.fenceCapacityExceeded))
        ] {
            let policy = try XCTUnwrap(WorkspaceCodemapGraphPolicy(maximumFencedFileIDCount: capacity))
            let capped = try await CodemapGraphIndexHarness(seed: 0xC7, graphPolicy: policy)
            try await capped.publishComplete([
                capped.terraformSlot(
                    0,
                    "projects/demo/calls.tf",
                    definitions: [
                        .call(name: "a", source: .literal("../../modules/a")),
                        .call(name: "b", source: .literal("../../modules/b"))
                    ],
                    references: [.childFolder(call: "a")]
                ),
                capped.terraformSlot(1, "projects/demo/one.tf", references: readsBoth),
                capped.terraformSlot(2, "projects/demo/two.tf", references: readsBoth)
            ])
            let disposition = await capped.graph.fenceFiles(fileIDs: [capped.fileID(0, lane: Self.lane)], reason: .deleted)
            XCTAssertEqual(disposition, expected, "capacity \(capacity)")
        }
    }

    // MARK: - Bounded work

    @MainActor
    func testSingleCallEditWorkDoesNotScaleWithUnrelatedFolders() async throws {
        struct Work {
            let changedFileCount: Int
            let affectedSourcePaths: Set<String>
            let reconcileVisits: UInt64
            let visits: UInt64
            let comparisons: UInt64
        }
        var work: [Int: Work] = [:]
        for unrelatedFileCount in [200, 2000] {
            let label = "\(unrelatedFileCount) unrelated files"
            let harness = try await CodemapGraphIndexHarness(seed: 0xC5)
            let slots = try Self.demoLayout(harness) + [
                harness.terraformSlot(12, "modules/other/outputs.tf", definitions: [.output(name: "endpoint")])
            ] + (0 ..< unrelatedFileCount).map { try Self.unrelatedSlot(harness, $0) }
            // Like an index page, the setup leaves enumeration unfinished. Completing it reconciles the
            // overlay's whole root, so the measured edit is a page publication.
            let published = await harness.publish(slots, projectedTotal: UInt64(slots.count))
            XCTAssertTrue(published, label)
            guard case .committed = await harness.pull() else { return XCTFail("\(label): the layout must commit") }
            // The commit looks up fences only for the call's declaring file, whatever else is fenced.
            let unrelatedIDs = Set((0 ..< unrelatedFileCount).map { harness.fileID(100 + $0, lane: Self.lane) })
            let fenced = await harness.graph.fenceFiles(fileIDs: unrelatedIDs, reason: .deleted)
            guard case .fenced = fenced else { return XCTFail("\(label): the unrelated files must fence, got \(fenced)") }

            let ledgerBefore = try await harness.ledger()
            let disposition = try await harness.publishCommitted(
                [Self.callFile(harness, source: .literal("../../modules/other"), generation: 2)],
                enumerationFinished: false,
                label
            )
            // `resync: false`: the graph commits the edit as a diff.
            guard case let .committed(_, _, changedFileCount, _, false) = disposition else {
                return XCTFail("\(label): the edit must commit a diff, got \(disposition)")
            }
            // The overlay reconciles only the published path, never the root's whole slot set.
            let ledgerAfter = try await harness.ledger()
            XCTAssertEqual(ledgerAfter.fullReconcileCount, ledgerBefore.fullReconcileCount, label)
            XCTAssertEqual(ledgerAfter.incrementalFallbackCount, ledgerBefore.incrementalFallbackCount, label)
            XCTAssertEqual(ledgerAfter.incrementalReconcileCount, ledgerBefore.incrementalReconcileCount + 1, label)
            let accounting = await harness.graph.incrementalAccounting()
            let snapshot = try await harness.latestSnapshot()
            let affectedSourceIDs = await harness.graph.lastAffectedSourceIDsForTesting()
            work[unrelatedFileCount] = Work(
                changedFileCount: changedFileCount,
                affectedSourcePaths: Set(affectedSourceIDs.map { Self.path($0, in: snapshot) }),
                reconcileVisits: ledgerAfter.lastReconcileVisitCount,
                visits: accounting.lastCandidateVisitCount,
                comparisons: accounting.lastCandidateComparisonCount
            )
        }
        let small = try XCTUnwrap(work[200])
        let large = try XCTUnwrap(work[2000])
        XCTAssertEqual(small.changedFileCount, 1)
        XCTAssertEqual(large.changedFileCount, 1)
        // The call file and its sibling consumer, and nothing in an unrelated folder.
        XCTAssertEqual(small.affectedSourcePaths, ["projects/demo/compute.tf", "projects/demo/outputs.tf"])
        XCTAssertEqual(large.affectedSourcePaths, small.affectedSourcePaths)
        XCTAssertEqual(large.reconcileVisits, small.reconcileVisits)
        // These equalities guard the instrumented counters: the visits the commit charges for Terraform
        // tuples, postings, both call indexes, and its fence lookups, and the comparisons its sorts
        // charge. Copied entries aren't asserted: they roughly double between these sizes as the
        // persistent maps' tries gain a level, more than copying a tenth of the nodes on every commit
        // would add.
        XCTAssertEqual(large.visits, small.visits)
        XCTAssertEqual(large.comparisons, small.comparisons)
    }

    // MARK: - Fixtures

    private static let lane: UInt8 = 0x30
    private static let workerSource = TerraformModuleSource.literal("../../modules/worker")

    private enum Evidence {
        static let workerCall = #"terraform "projects/demo"::module."worker""#
        static let workerSource = #"terraform "projects/demo"::module."worker" source -> "modules/worker""#
        static let workerInput =
            #"terraform "projects/demo"::module."worker" input "project_id" -> "modules/worker"::var."project_id""#
        static let workerOutput =
            #"terraform "projects/demo"::module."worker" output "endpoint" -> "modules/worker"::output."endpoint""#
        static let childVariable = #"terraform "modules/worker"::var."project_id""#
        static let childResource = #"terraform "modules/worker"::resource."null_resource"."worker""#
        // A withheld child reference doesn't name a target.
        static let workerSourceWithheld = #"terraform "projects/demo"::module."worker" source"#
        static let workerInputWithheld = #"terraform "projects/demo"::module."worker" input "project_id""#
        static let workerOutputWithheld = #"terraform "projects/demo"::module."worker" output "endpoint""#
    }

    /// A stack that calls `modules/worker`, and a sibling file that reads the call's output.
    private static func demoLayout(
        _ harness: CodemapGraphIndexHarness,
        source: TerraformModuleSource = workerSource
    ) throws -> [WorkspaceCodemapGraphSlot] {
        try [
            callFile(harness, source: source, generation: 1),
            harness.terraformSlot(
                1,
                "projects/demo/outputs.tf",
                definitions: [.output(name: "endpoint")],
                references: [.call(name: "worker"), .childOutput(call: "worker", output: "endpoint")]
            ),
            harness.terraformSlot(
                2,
                "modules/worker/main.tf",
                definitions: [.resource(type: "null_resource", name: "worker")],
                references: [.variable(name: "project_id")]
            ),
            harness.terraformSlot(3, "modules/worker/variables.tf", definitions: [.variable(name: "project_id")]),
            harness.terraformSlot(
                4,
                "modules/worker/outputs.tf",
                definitions: [.output(name: "endpoint")],
                references: [.resource(type: "null_resource", name: "worker")]
            )
        ]
    }

    /// One file of an unrelated stack that calls `modules/worker`: an even index declares the call,
    /// and an odd index reads its output. Both declare the names the demo stack's child declares, so
    /// every unrelated folder adds postings and entries to both call indexes.
    private static func unrelatedSlot(_ harness: CodemapGraphIndexHarness, _ index: Int) throws -> WorkspaceCodemapGraphSlot {
        let names: [Definition] = [.variable(name: "project_id"), .output(name: "endpoint")]
        let references: [Reference] = index.isMultiple(of: 2)
            ? [.childFolder(call: "worker"), .childInput(call: "worker", argument: "project_id")]
            : [.call(name: "worker"), .childOutput(call: "worker", output: "endpoint")]
        return try harness.terraformSlot(
            100 + index,
            "unrelated/module\(index / 2)/file\(index % 2).tf",
            definitions: index.isMultiple(of: 2) ? names + [.call(name: "worker", source: workerSource)] : names,
            references: references + [.variable(name: "project_id")]
        )
    }

    private static func callFileID(_ harness: CodemapGraphIndexHarness) -> UUID {
        harness.fileID(0, lane: lane)
    }

    /// A second declaration of the `worker` call with a valid source.
    private static func secondCallFile(
        _ harness: CodemapGraphIndexHarness,
        path: String,
        generation: UInt64
    ) throws -> WorkspaceCodemapGraphSlot {
        try harness.terraformSlot(
            20,
            path,
            definitions: [.call(name: "worker", source: workerSource)],
            references: [.childFolder(call: "worker")],
            generation: generation
        )
    }

    private static func callFile(
        _ harness: CodemapGraphIndexHarness,
        index: Int = 0,
        path: String = "projects/demo/compute.tf",
        source: TerraformModuleSource,
        generation: UInt64
    ) throws -> WorkspaceCodemapGraphSlot {
        try harness.terraformSlot(
            index,
            path,
            definitions: [.call(name: "worker", source: source)],
            references: [.childFolder(call: "worker"), .childInput(call: "worker", argument: "project_id")],
            generation: generation
        )
    }

    private struct EdgeRow: Hashable, CustomStringConvertible {
        let source: String
        let target: String
        let names: [String]
        let candidateCount: UInt64
        let ambiguous: Bool

        init(_ source: String, _ target: String, _ names: [String], _ candidateCount: UInt64) {
            self.init(source, target, names, candidateCount, ambiguous: candidateCount > 1)
        }

        init(_ source: String, _ target: String, _ names: [String], _ candidateCount: UInt64, ambiguous: Bool) {
            self.source = source
            self.target = target
            self.names = names
            self.candidateCount = candidateCount
            self.ambiguous = ambiguous
        }

        var description: String {
            "\(source) -> \(target) \(names) count \(candidateCount)\(ambiguous ? " ambiguous" : "")"
        }
    }

    private struct UnresolvedRow: Hashable, CustomStringConvertible {
        let source: String
        let name: String
        let reason: WorkspaceCodemapGraphUnresolvedReason

        init(_ source: String, _ name: String, _ reason: WorkspaceCodemapGraphUnresolvedReason) {
            self.source = source
            self.name = name
            self.reason = reason
        }

        var description: String {
            "\(source): \(name) \(reason)"
        }
    }

    private static func path(_ fileID: UUID, in snapshot: WorkspaceCodemapGraphCommittedSnapshot) -> String {
        snapshot.nodesByFileID[fileID]?.standardizedRelativePath ?? "<missing \(fileID)>"
    }

    private static func edgeRows(_ snapshot: WorkspaceCodemapGraphCommittedSnapshot) -> Set<EdgeRow> {
        Set(snapshot.outgoingEdgesBySource.values.joined().map {
            EdgeRow(
                path($0.sourceFileID, in: snapshot),
                path($0.targetFileID, in: snapshot),
                $0.matchedNames,
                $0.candidateCount,
                ambiguous: $0.ambiguous
            )
        })
    }

    private static func unresolvedRows(_ snapshot: WorkspaceCodemapGraphCommittedSnapshot) -> Set<UnresolvedRow> {
        Set(snapshot.unresolvedBySource.values.joined().map {
            UnresolvedRow(path($0.sourceFileID, in: snapshot), $0.referencedName, $0.reason)
        })
    }

    /// Targets of the source's direct child-output links, sorted.
    private static func outputTargets(_ snapshot: WorkspaceCodemapGraphCommittedSnapshot, sourceID: UUID) -> [String] {
        (snapshot.outgoingEdgesBySource[sourceID] ?? [])
            .filter { $0.matchedNames.contains { $0.contains(" output ") } }
            .map { path($0.targetFileID, in: snapshot) }
            .sorted()
    }
}

private extension CodemapGraphIndexHarness {
    /// A Terraform slot whose contribution holds folder membership plus `definitions` and
    /// `references`, encoded by the `tf1` codec.
    func terraformSlot(
        _ index: Int,
        _ path: String,
        definitions: [TerraformCodeMapGraphNames.Definition] = [],
        references: [TerraformCodeMapGraphNames.Reference] = [],
        generation: UInt64 = 1
    ) throws -> WorkspaceCodemapGraphSlot {
        try makeSlot(
            fileID: fileID(index, lane: 0x30),
            path: path,
            definitions: ([.folder] + definitions).map(\.encoded),
            references: references.map(\.encoded),
            requestGeneration: generation,
            pathGeneration: generation,
            language: .terraform
        )
    }

    /// Publishes every slot of a root whose enumeration is complete, then applies it.
    func publishComplete(_ slots: [WorkspaceCodemapGraphSlot]) async throws {
        let published = await publish(slots, projectedTotal: UInt64(slots.count), enumerationFinished: true)
        guard published else { throw CodemapGraphIndexHarnessError.unexpectedDisposition("rejected publication") }
        guard case .committed = await pull() else {
            throw CodemapGraphIndexHarnessError.unexpectedDisposition("uncommitted publication")
        }
    }

    /// Publishes a change, applies it, and returns the commit. A publication that doesn't finish
    /// enumeration leaves coverage partial. A change finishes it by default, so coverage stays
    /// complete unless a slot is pending.
    @discardableResult
    func publishCommitted(
        _ slots: [WorkspaceCodemapGraphSlot],
        enumerationFinished: Bool = true,
        _ label: String = ""
    ) async throws -> WorkspaceCodemapGraphApplyDisposition {
        let published = await publish(slots, enumerationFinished: enumerationFinished)
        guard published else { throw CodemapGraphIndexHarnessError.unexpectedDisposition("\(label): rejected publication") }
        let disposition = await pull()
        guard let disposition, case .committed = disposition else {
            throw CodemapGraphIndexHarnessError.unexpectedDisposition("\(label): \(String(describing: disposition))")
        }
        return disposition
    }

    func structure(
        seed: UUID,
        direction: WorkspaceCodemapStructureTraversalDirection
    ) async throws -> WorkspaceCodemapGraphStructureRootResult {
        try await graph.traverseLatest(WorkspaceCodemapGraphStructureQuery(
            seedFileIDs: [seed],
            direction: direction,
            maximumDepth: 1,
            budget: WorkspaceCodemapGraphPolicy.initial.queryBudget(size: .large, includesSignatures: false)
        ))
    }

    func automaticSelection(source: UUID) async throws -> WorkspaceCodemapAutomaticSelectionGraphQueryResult {
        let generation = try await latestSnapshot().slotsByFileID[source]?.requestGeneration ?? 1
        let disposition = await graph.automaticSelectionLatest(WorkspaceCodemapAutomaticSelectionGraphQuery(
            rootEpoch: rootEpoch,
            sources: [WorkspaceCodemapAutomaticSelectionGraphSeed(fileID: source, requestGeneration: generation)],
            maximumTargetCount: 100,
            maximumResolutionCount: 100,
            maximumReferenceFailureCount: 100,
            maximumByteCount: 1 << 20
        ))
        guard case let .ready(result) = disposition else {
            throw CodemapGraphIndexHarnessError.unexpectedDisposition("\(disposition)")
        }
        return result
    }
}
