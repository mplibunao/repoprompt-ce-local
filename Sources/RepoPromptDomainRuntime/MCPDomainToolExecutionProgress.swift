import Foundation

/// Names the await boundary an MCP tool invocation most recently reached.
///
/// Each value is reported immediately before the await it names (`started`) and, where later work
/// is not instrumented, after it returns (`completed`). The recorder keeps only the latest report,
/// so a `started` report that stays latest names the await that has not returned. A dotted raw
/// value extends its parent's, so log grouping by the parent prefix keeps working. Phases in shared
/// code (`file_tool_authority`, `protected_mutation`, `filesystem_mutation`, `workspace_store`) are
/// tool-agnostic; the trace that carries them also names the tool.
package enum MCPToolExecutionHandlerPhase: String, Equatable, Sendable {
    case manageSelectionAutoSelectionDrain = "manage_selection.auto_selection_drain"
    case manageSelectionIngressWait = "manage_selection.ingress_wait"
    case manageSelectionConstruction = "manage_selection.selection_construction"
    /// Child intervals of the aggregate construction phase. The aggregate raw value stays their
    /// prefix so existing log grouping keeps working, while the watchdog packet can name the
    /// specific stalled interval instead of the combined one. The first three each cover a single
    /// awaited dependency; the fourth covers operation-specific construction, which spans the
    /// caller's per-operation work.
    case manageSelectionConstructionVirtualSelectionStabilization =
        "manage_selection.selection_construction.virtual_selection_stabilization"
    case manageSelectionConstructionGitReviewContextFreeze =
        "manage_selection.selection_construction.git_review_context_freeze"
    case manageSelectionConstructionArtifactInputResolution =
        "manage_selection.selection_construction.artifact_input_resolution"
    case manageSelectionConstructionOperationSpecificConstruction =
        "manage_selection.selection_construction.operation_specific_construction"
    case manageSelectionPersistence = "manage_selection.persistence"
    case manageSelectionReplyConstruction = "manage_selection.reply_construction"
    case fileActionsPreMutationChecks = "file_actions.pre_mutation_checks"
    case fileActionsCatalogEligibility = "file_actions.catalog_eligibility"
    case fileActionsMutationIO = "file_actions.mutation_io"
    case fileActionsPostMutationCatalog = "file_actions.post_mutation_catalog"
    case fileActionsPostMutationSelection = "file_actions.post_mutation_selection"
    case fileActionsReplyConstruction = "file_actions.reply_construction"
    case readFileRequestResolution = "read_file.request_resolution"
    case readFileContentRead = "read_file.content_read"
    case readFileContentReadGitArtifactPreflight = "read_file.content_read.git_artifact_preflight"
    case readFileContentReadRootCapture = "read_file.content_read.root_capture"
    case readFileContentReadFreshness = "read_file.content_read.freshness"
    case readFileContentReadExactResolution = "read_file.content_read.exact_resolution"
    case readFileContentReadSeededAuthority = "read_file.content_read.seeded_authority"
    case readFileContentReadFingerprint = "read_file.content_read.fingerprint"
    /// The shared interactive-read cache lookup, including a wait on another reader's flight and
    /// the flight's physical load and preparation. The flight runs in a task shared by every
    /// waiter, so it reports no phases of its own.
    case readFileContentReadCachedContent = "read_file.content_read.cached_content"
    case readFileContentReadReplyPreparation = "read_file.content_read.reply_preparation"
    case readFileReplyProjection = "read_file.reply_projection"
    case readFileAuthorityValidation = "read_file.authority_validation"
    case readFileAutoSelection = "read_file.auto_selection"
    case readFileValueEncoding = "read_file.value_encoding"
    case getFileTreeRequestResolution = "get_file_tree.request_resolution"
    case getFileTreeIngressWait = "get_file_tree.ingress_wait"
    case getFileTreeConstruction = "get_file_tree.construction"
    case promptExportSelectionDrain = "prompt_export.selection_drain"
    case promptExportPresetResolution = "prompt_export.preset_resolution"
    case promptExportContentAssembly = "prompt_export.content_assembly"
    case promptExportMetadataAssembly = "prompt_export.metadata_assembly"
    case promptExportDestinationAuthorization = "prompt_export.destination_authorization"
    case promptExportDurableWrite = "prompt_export.durable_write"
    case promptExportIngressWait = "prompt_export.ingress_wait"
    case promptExportReplyAssembly = "prompt_export.reply_assembly"
    case promptExportFormatting = "prompt_export.formatting"
    case promptExportPublication = "prompt_export.publication"
    /// `prompt` set, append, clear, and select_preset writing the tab's prompt state.
    case promptMutationPublication = "prompt_mutation.publication"
    case promptMutationReplyConstruction = "prompt_mutation.reply_construction"
    // Graph-first get_code_structure execution stages.
    case getCodeStructureSeedResolution = "get_code_structure.seed_resolution"
    case getCodeStructureIngressWait = "get_code_structure.ingress_wait"
    case getCodeStructureGraphSnapshot = "get_code_structure.graph_snapshot"
    case getCodeStructureGraphTraversal = "get_code_structure.graph_traversal"
    case getCodeStructureGraphRevalidation = "get_code_structure.graph_revalidation"
    case getCodeStructureRenderDemand = "get_code_structure.render_demand"
    case getCodeStructureFreeze = "get_code_structure.freeze"
    case getCodeStructureRender = "get_code_structure.render"
    case getCodeStructureAssembly = "get_code_structure.assembly"
    case applyEditsRouting = "apply_edits.routing"
    case applyEditsRootCapture = "apply_edits.root_capture"
    case applyEditsFreshness = "apply_edits.freshness"
    case applyEditsTargetResolution = "apply_edits.target_resolution"
    case applyEditsRootMappings = "apply_edits.root_mappings"
    case applyEditsTabResolution = "apply_edits.tab_resolution"
    case applyEditsApprovalLookup = "apply_edits.approval_lookup"
    case applyEditsPreviewRead = "apply_edits.preview_read"
    case applyEditsPreviewTransform = "apply_edits.preview_transform"
    case applyEditsApprovalWait = "apply_edits.approval_wait"
    case applyEditsWrite = "apply_edits.write"
    case applyEditsPostWriteFreshness = "apply_edits.post_write_freshness"
    case applyEditsReplyConstruction = "apply_edits.reply_construction"
    /// Frozen file-tool authority, shared by the structure-backed file tools.
    case fileToolAuthorityRootCatalogWait = "file_tool_authority.root_catalog_wait"
    case fileToolAuthorityLookupResolution = "file_tool_authority.lookup_resolution"
    case fileToolAuthorityCapture = "file_tool_authority.capture"
    case fileToolAuthorityValidation = "file_tool_authority.validation"
    /// The journaled wrapper shared by every protected mutation tool.
    case protectedMutationAuthorization = "protected_mutation.authorization"
    case protectedMutationJournalBegin = "protected_mutation.journal_begin"
    case protectedMutationPhysicalAdmission = "protected_mutation.physical_admission"
    case protectedMutationCommitPreparation = "protected_mutation.commit_preparation"
    case protectedMutationPhysicalGuard = "protected_mutation.physical_guard"
    case protectedMutationJournalFinalization = "protected_mutation.journal_finalization"
    /// Uncancellable filesystem I/O shared by the file-editing tools.
    case filesystemMutationIOWait = "filesystem_mutation.io_wait"
    /// Workspace-store waits reached by several tools.
    case workspaceStoreEditPublication = "workspace_store.edit_publication"
    case workspaceStoreCodemapRootFenceWait = "workspace_store.codemap_root_fence_wait"
    case workspaceStoreCodemapPathQuiescenceWait = "workspace_store.codemap_path_quiescence_wait"
}

package enum MCPToolExecutionHandlerPhaseTransition: String, Equatable, Sendable {
    case started
    case completed
}

package struct MCPToolExecutionHandlerPhaseSnapshot: Equatable, Sendable {
    package let phase: MCPToolExecutionHandlerPhase
    package let transition: MCPToolExecutionHandlerPhaseTransition
    package let elapsedMilliseconds: Double

    package init(
        phase: MCPToolExecutionHandlerPhase,
        transition: MCPToolExecutionHandlerPhaseTransition,
        elapsedMilliseconds: Double
    ) {
        self.phase = phase
        self.transition = transition
        self.elapsedMilliseconds = elapsedMilliseconds
    }
}

/// Per-invocation progress state. Providers use the task-local accessor while the
/// connection manager retains this recorder explicitly for watchdog escalation and the
/// settlement registry reads it for diagnostics.
///
/// Recording is synchronous and takes only this lock, so a provider can mark an await boundary
/// from any isolation without an executor hop.
package final class MCPToolExecutionHandlerPhaseRecorder: @unchecked Sendable {
    /// Clock reading the elapsed values are measured from.
    package let origin: Duration
    private let lock = NSLock()
    private let now: @Sendable () -> Duration
    private var latest: MCPToolExecutionHandlerPhaseSnapshot?

    package init(
        origin: Duration,
        now: @escaping @Sendable () -> Duration
    ) {
        self.origin = origin
        self.now = now
    }

    @discardableResult
    package func report(
        _ phase: MCPToolExecutionHandlerPhase,
        transition: MCPToolExecutionHandlerPhaseTransition
    ) -> MCPToolExecutionHandlerPhaseSnapshot {
        let snapshot = MCPToolExecutionHandlerPhaseSnapshot(
            phase: phase,
            transition: transition,
            elapsedMilliseconds: max(0, Self.milliseconds(now() - origin))
        )
        lock.withLock { latest = snapshot }
        return snapshot
    }

    package func snapshot() -> MCPToolExecutionHandlerPhaseSnapshot? {
        lock.withLock { latest }
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}

package enum MCPToolExecutionHandlerPhaseContext {
    @TaskLocal
    package static var recorder: MCPToolExecutionHandlerPhaseRecorder?

    #if DEBUG
        private final class DebugState: @unchecked Sendable {
            let lock = NSLock()
            var sink: (@Sendable (MCPToolExecutionHandlerPhaseSnapshot) -> Void)?
        }

        private static let debugState = DebugState()
    #endif

    /// Records `phase` on the current invocation's recorder; a no-op outside an MCP invocation.
    package static func report(
        _ phase: MCPToolExecutionHandlerPhase,
        transition: MCPToolExecutionHandlerPhaseTransition = .started
    ) {
        guard let recorder else { return }
        report(phase, transition: transition, using: recorder)
    }

    @discardableResult
    package static func report(
        _ phase: MCPToolExecutionHandlerPhase,
        transition: MCPToolExecutionHandlerPhaseTransition = .started,
        using recorder: MCPToolExecutionHandlerPhaseRecorder
    ) -> MCPToolExecutionHandlerPhaseSnapshot {
        let snapshot = recorder.report(phase, transition: transition)
        #if DEBUG
            let sink = debugState.lock.withLock { debugState.sink }
            sink?(snapshot)
        #endif
        return snapshot
    }

    #if DEBUG
        package static func setTestSink(_ sink: (@Sendable (MCPToolExecutionHandlerPhaseSnapshot) -> Void)?) {
            debugState.lock.withLock { debugState.sink = sink }
        }
    #endif
}
