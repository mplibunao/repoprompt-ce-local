import Foundation
import MCP
@testable import RepoPromptApp
import XCTest

/// `get_code_structure` over parsed `.tf` files, through the committed graph, the reply DTO, its
/// JSON wire form, and the rendered text.
final class TerraformCodeStructureTests: XCTestCase {
    /// Runs on the main actor because XCTest can drop an off-main assertion failure that it hasn't
    /// recorded by the time an async test returns.
    @MainActor
    func testStructureRendersScopedLinksAndUnresolvedSourceReasons() async throws {
        let repository = try ReviewGitRepositoryFixture(name: #function)
        let rootURL = try repository.makeRepository(named: "infra", files: [
            "projects/demo/compute.tf": """
            module "worker" {
              source     = "../../modules/worker"
              project_id = "demo"
            }

            module "registry" {
              source = "example/registry/module"
            }

            module "escape" {
              source = "../../../outside"
            }

            module "unsourced" {
            }

            module "twice" {
              source = "../../modules/worker"
            }

            module "twice" {
              source = "../../modules/worker"
            }

            """,
            "projects/demo/outputs.tf": "output \"endpoint\" {\n  value = module.worker[0].endpoint\n}\n",
            "modules/worker/main.tf": "resource \"null_resource\" \"worker\" {\n  triggers = { project = var.project_id }\n}\n",
            "modules/worker/variables.tf": "variable \"project_id\" {\n  type = string\n}\n",
            "modules/worker/outputs.tf": "output \"endpoint\" {\n  value = null_resource.worker.id\n}\n"
        ])
        let fixture = try CodemapStoreFixture(name: #function)
        let store = fixture.makeStore()
        let loaded = try await store.loadRoot(path: rootURL.path)
        addTeardownBlock {
            await store.unloadRoot(id: loaded.id)
            await fixture.shutdown()
            repository.cleanup()
        }
        let files = await store.files(inRoot: loaded.id)
        let compute = try XCTUnwrap(files.first { $0.standardizedRelativePath == "projects/demo/compute.tf" })
        let outputs = try XCTUnwrap(files.first { $0.standardizedRelativePath == "projects/demo/outputs.tf" })

        // The call file links to every file of the child folder. The edge to `variables.tf` also
        // carries the input, so it alone isn't ambiguous. Each unusable call reports its own reason.
        let calls = try await structure(store: store, seed: compute, depth: 1)
        let callRoot = try XCTUnwrap(calls.dto.roots.first)
        XCTAssertEqual(callRoot.edges, [
            Edge(from: "infra/projects/demo/compute.tf", to: "infra/modules/worker/main.tf", symbols: [Evidence.workerSource], ambiguous: true),
            Edge(from: "infra/projects/demo/compute.tf", to: "infra/modules/worker/outputs.tf", symbols: [Evidence.workerSource], ambiguous: true),
            Edge(
                from: "infra/projects/demo/compute.tf",
                to: "infra/modules/worker/variables.tf",
                symbols: [Evidence.workerInput, Evidence.workerSource],
                ambiguous: nil
            )
        ])
        XCTAssertEqual(callRoot.unresolved.map(\.name), [
            #"terraform "projects/demo"::module."escape" source"#,
            #"terraform "projects/demo"::module."registry" source"#,
            #"terraform "projects/demo"::module."twice" source"#,
            #"terraform "projects/demo"::module."unsourced" source"#
        ])
        XCTAssertEqual(calls.unresolvedWireReasons, [
            "outside_loaded_root",
            "unsupported_module_source",
            "ambiguous_module_call",
            "invalid_module_call"
        ])
        XCTAssertEqual(calls.graphLines, [
            "- `projects/demo/compute.tf` (seed) → uses:",
            "  - `modules/worker/main.tf` — \(Evidence.workerSource) (ambiguous)",
            "  - `modules/worker/outputs.tf` — \(Evidence.workerSource) (ambiguous)",
            "  - `modules/worker/variables.tf` — \(Evidence.workerInput), \(Evidence.workerSource)"
        ])

        // The output file reaches the call and the child output directly. Only the second hop adds
        // the files those two link to.
        let oneHop = try await structure(store: store, seed: outputs, depth: 1)
        XCTAssertEqual(oneHop.nodeDepths, [
            "infra/projects/demo/outputs.tf": 0,
            "infra/modules/worker/outputs.tf": 1,
            "infra/projects/demo/compute.tf": 1
        ])
        XCTAssertEqual(oneHop.graphLines, [
            "- `projects/demo/outputs.tf` (seed) → uses:",
            "  - `modules/worker/outputs.tf` — \(Evidence.workerOutput)",
            "  - `projects/demo/compute.tf` — \(Evidence.workerCall)"
        ])
        let twoHops = try await structure(store: store, seed: outputs, depth: 2)
        XCTAssertEqual(twoHops.nodeDepths, [
            "infra/projects/demo/outputs.tf": 0,
            "infra/modules/worker/outputs.tf": 1,
            "infra/projects/demo/compute.tf": 1,
            "infra/modules/worker/main.tf": 2,
            "infra/modules/worker/variables.tf": 2
        ])
        XCTAssertTrue(twoHops.graphLines.contains(
            #"  - `modules/worker/main.tf` — terraform "modules/worker"::resource."null_resource"."worker""#
        ))
    }

    private typealias Edge = ToolResultDTOs.CodeStructureReplyDTO.EdgeDTO

    private enum Evidence {
        static let workerCall = #"terraform "projects/demo"::module."worker""#
        static let workerSource = #"terraform "projects/demo"::module."worker" source -> "modules/worker""#
        static let workerInput =
            #"terraform "projects/demo"::module."worker" input "project_id" -> "modules/worker"::var."project_id""#
        static let workerOutput =
            #"terraform "projects/demo"::module."worker" output "endpoint" -> "modules/worker"::output."endpoint""#
    }

    private struct StructureReply {
        let dto: ToolResultDTOs.CodeStructureReplyDTO
        /// `reason` of each unresolved reference of the first root, as the JSON reply spells it.
        let unresolvedWireReasons: [String]
        /// The rendered `### Graph` section, without its heading.
        let graphLines: [String]

        var nodeDepths: [String: Int] {
            Dictionary(uniqueKeysWithValues: (dto.roots.first?.nodes ?? []).map { ($0.path, $0.depth) })
        }
    }

    /// Projects a `uses` query through the reply DTO, as `get_code_structure` with `signatures: false`
    /// does, and retries while the root is still indexing.
    @MainActor
    private func structure(
        store: WorkspaceFileContextStore,
        seed: WorkspaceFileRecord,
        depth: Int
    ) async throws -> StructureReply {
        let budget = WorkspaceCodemapGraphPolicy.initial.queryBudget(size: .large, includesSignatures: false)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(20))
        var dto: ToolResultDTOs.CodeStructureReplyDTO?
        while clock.now < deadline {
            let aggregate = try await store.queryCodemapStructureGraphs(
                seedFileIDs: [seed.id],
                direction: .referencedDefinitions,
                maximumDepth: depth,
                budget: budget,
                rootScope: .allLoaded
            )
            let reply = await MCPServerViewModel.codeStructureReplyDTO(
                aggregate: aggregate,
                presentation: nil,
                revalidation: store.revalidateCodemapStructureGraphs(aggregate),
                includesSignatures: false,
                budget: budget,
                size: .large,
                worktreeScope: nil
            )
            if let root = reply.roots.first, root.index.state == .complete,
               root.seeds.allSatisfy({ $0.state == .covered })
            {
                dto = reply
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        let ready = try XCTUnwrap(dto, "The root did not finish indexing")

        let value = try Value(ready)
        let wire = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any]
        let roots = try XCTUnwrap(wire?["roots"] as? [[String: Any]])
        let unresolved = try XCTUnwrap(roots.first?["unresolved"] as? [[String: Any]])

        let text = try XCTUnwrap(ToolOutputFormatter.formatCodeStructure(value: value).lazy.compactMap { block -> String? in
            guard case let .text(text, _, _) = block else { return nil }
            return text
        }.first)
        let graph = text.components(separatedBy: "\n")
            .drop(while: { $0 != "### Graph" })
            .dropFirst()
            .prefix(while: { !$0.isEmpty })

        return StructureReply(
            dto: ready,
            unresolvedWireReasons: unresolved.compactMap { $0["reason"] as? String },
            graphLines: Array(graph)
        )
    }
}
