import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

final class BindContextOutputFormattingTests: XCTestCase {
    func testUnfilteredMultiWindowListKeepsCompactWindowsBlock() throws {
        let text = try formattedList(windowID: nil, windows: twoWindows())

        XCTAssertEqual(try windowsBlock(of: text), """
        ### Windows
        - **Count**: 2

        - Window `3` [current] • workspace: Discovery • 4 tabs
          repo: `/tmp/rp-discovery`
          • active: Active — context_id: `00000000-0000-0000-0000-000000000001`
          • bound: Bound — context_id: `00000000-0000-0000-0000-000000000002`
        - Window `5` • workspace: Other • 1 tab
          repo: `/tmp/rp-other`
          • active: Main — context_id: `00000000-0000-0000-0000-000000000005`
        """)
    }

    func testWindowFilteredListShowsEveryComposeTabIncludingInactiveUnbound() throws {
        let text = try formattedList(windowID: 3, windows: [twoWindows()[0]])

        XCTAssertEqual(try windowsBlock(of: text), """
        ### Windows
        - **Count**: 1 (filtered by window_id)

        - Window `3` [current] • workspace: Discovery
          • active_context_id: `00000000-0000-0000-0000-000000000001`
          • Active [active] — context_id: `00000000-0000-0000-0000-000000000001`
            repo: `/tmp/rp-discovery`
          • Bound [bound] — context_id: `00000000-0000-0000-0000-000000000002`
            repo: `/tmp/rp-discovery`
          • Idle One — context_id: `00000000-0000-0000-0000-000000000003`
            repo: `/tmp/rp-discovery`
          • Idle Two — context_id: `00000000-0000-0000-0000-000000000004`
            repo: `/tmp/rp-discovery`
        """)
    }

    func testNextStepsBindDirectlyAndExpandAWindowOnlyWhenTabsAreOmitted() throws {
        let bindListedTab = #"{"op":"bind","context_id":"<context_id>"}"#
        let expandWindow = #"{"op":"list","window_id":3}"#
        let bindWindow = #"{"op":"bind","window_id":3}"#
        let windows = try twoWindows()
        let cases: [(label: String, filter: Int?, windows: [MCPBindContextWindowSummary], calls: [String])] = [
            ("compact multi-window list omits tabs", nil, windows, [bindListedTab, expandWindow, bindWindow]),
            ("single-window list shows every tab", nil, [windows[0]], [bindListedTab, bindWindow]),
            ("filtered list shows every tab", 3, [windows[0]], [bindListedTab, bindWindow])
        ]
        for testCase in cases {
            let text = try formattedList(windowID: testCase.filter, windows: testCase.windows)
            XCTAssertEqual(try hintedCalls(in: nextSteps(of: text)), testCase.calls, testCase.label)
        }
    }

    @MainActor
    func testDomainBindingAdvertisesCanonicalDefinitionWhileRegistrationKeepsItsFullerDescription() async throws {
        let registered = try await registeredBindContextTool()
        let canonical = try XCTUnwrap(
            MCPDomainCanonicalToolDefinitions.definition(named: MCPGlobalToolName.bindContext)
        )

        XCTAssertEqual(try registered.domainBinding().definition, canonical)
        XCTAssertNotEqual(registered.description, canonical.description)
        // A client pays for the canonical text on each tools/list that advertises the tool;
        // the registration's text is read on demand.
        XCTAssertLessThan(canonical.description.count, registered.description.count)
    }

    @MainActor
    func testHintedArgumentsMatchProjectedCanonicalSchema() async throws {
        let canonical = try XCTUnwrap(
            MCPDomainCanonicalToolDefinitions.definition(named: MCPGlobalToolName.bindContext)
        )
        let projectedCanonicalSchema = ServerNetworkManager.augmentSchemaWithCanonicalBindingParams(
            canonical.inputSchema,
            toolName: MCPGlobalToolName.bindContext,
            purpose: .unknown
        )
        XCTAssertEqual(projectedCanonicalSchema, canonical.inputSchema)
        // The JSONSchema bridge must carry the working_dirs union and window_id unchanged.
        let projected = try Tool(canonicalizing: Tool(
            name: MCPGlobalToolName.bindContext,
            description: "",
            inputSchema: .object(),
            returnsValue: { _ in .null }
        ))
        XCTAssertEqual(try Value(projected.inputSchema), canonical.inputSchema)

        let schema = try XCTUnwrap(projectedCanonicalSchema.objectValue)
        let windows = try twoWindows()
        // The canonical description is paid for on each tools/list, so it may carry no example;
        // every hint, routing error, and Settings text shows at least one.
        let surfaces: [(text: String, mustShowExample: Bool)] = try await [
            (nextSteps(of: formattedList(windowID: nil, windows: windows)), true),
            (nextSteps(of: formattedList(windowID: nil, windows: [windows[0]])), true),
            (nextSteps(of: formattedList(windowID: 3, windows: [windows[0]])), true),
            (ServerNetworkManager.multiWindowSelectionGuidance(), true),
            (canonical.description, false),
            (registeredBindContextTool().description, true)
        ]
        let listedContextID = try fixtureID(2).uuidString
        for (hint, mustShowExample) in surfaces {
            let examples = try hintedCalls(in: hint)
            if mustShowExample {
                XCTAssertFalse(examples.isEmpty, hint)
            }
            for example in examples {
                let call = example
                    .replacingOccurrences(of: "<window_id>", with: "3")
                    .replacingOccurrences(of: "<context_id>", with: listedContextID)
                let arguments = try XCTUnwrap(
                    Value.fromJSONString(call)?.objectValue,
                    "not a JSON object: \(call)"
                )
                XCTAssertEqual(schemaViolations(of: arguments, against: schema), [], call)
            }
            // The hidden one-shot routing argument is not an advertised parameter.
            XCTAssertFalse(hint.contains("_windowID"), hint)
        }
    }

    /// Every brace-delimited object in a hint is a hinted call, whichever key it starts with
    /// and whether or not the surface renders Markdown.
    private func hintedCalls(in hint: String) throws -> [String] {
        let regex = try NSRegularExpression(pattern: #"\{[^{}]*\}"#)
        return regex.matches(in: hint, range: NSRange(hint.startIndex..., in: hint)).compactMap { match in
            Range(match.range, in: hint).map { String(hint[$0]) }
        }
    }

    /// The raw registration is what Settings lists; its `domainBinding()` is what MCP advertises.
    @MainActor
    private func registeredBindContextTool() async throws -> RepoPromptApp.Tool {
        let service = WindowRoutingService(
            windowStates: WindowStatesManager.shared,
            networkMgr: ServerNetworkManager.shared
        )
        await service.prepareDomainTools()
        let tools = await service.tools
        return try XCTUnwrap(tools.first { $0.name == MCPGlobalToolName.bindContext })
    }

    /// Covers the JSON Schema subset the canonical tool definitions use: required keys, declared
    /// properties, enum, type, array items, and anyOf.
    private func schemaViolations(of arguments: [String: Value], against schema: [String: Value]) -> [String] {
        let properties = schema["properties"]?.objectValue ?? [:]
        let required = (schema["required"]?.arrayValue ?? []).compactMap(\.stringValue)
        var violations = required.filter { arguments[$0] == nil }.map { "missing required \($0)" }
        for (key, value) in arguments.sorted(by: { $0.key < $1.key }) {
            guard let property = properties[key] else {
                violations.append("\(key) is not declared")
                continue
            }
            if !conforms(value, to: property) {
                violations.append("\(key)=\(jsonText(value)) does not match its declared schema")
            }
        }
        return violations
    }

    private func conforms(_ value: Value, to schema: Value) -> Bool {
        guard let schema = schema.objectValue else { return false }
        if let branches = schema["anyOf"]?.arrayValue {
            return branches.contains { conforms(value, to: $0) }
        }
        if let allowed = schema["enum"]?.arrayValue, !allowed.contains(value) {
            return false
        }
        switch (schema["type"]?.stringValue ?? "", value) {
        case ("integer", .int), ("string", .string), ("boolean", .bool):
            return true
        case let ("array", .array(items)):
            guard let itemSchema = schema["items"] else { return true }
            return items.allSatisfy { conforms($0, to: itemSchema) }
        default:
            return false
        }
    }

    private func jsonText(_ value: Value) -> String {
        (try? JSONEncoder().encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "\(value)"
    }

    private func formattedList(windowID: Int?, windows: [MCPBindContextWindowSummary]) throws -> String {
        let binding = try MCPBindContextBindingSummary(
            bindingKind: "tab_context",
            windowID: 3,
            contextID: fixtureID(2),
            workspaceID: fixtureID(10),
            workspaceName: "Discovery",
            tabName: "Bound",
            repoPaths: ["/tmp/rp-discovery"],
            explicit: true,
            runScoped: false
        )
        var args: [String: Value] = ["op": .string("list")]
        if let windowID {
            args["window_id"] = .int(windowID)
        }
        let content = try ToolOutputFormatter.formatBindContext(
            args: args,
            value: Value(BindContextResponse(windows: windows, binding: binding))
        )
        return content.compactMap { item -> String? in
            if case let .text(text, _, _) = item { return text }
            return nil
        }.joined(separator: "\n")
    }

    private func twoWindows() throws -> [MCPBindContextWindowSummary] {
        let discovery = try MCPBindContextWorkspaceSummary(id: fixtureID(10), name: "Discovery")
        let discoveryTabs = try [
            (1, "Active", true, false),
            (2, "Bound", false, true),
            (3, "Idle One", false, false),
            (4, "Idle Two", false, false)
        ].map { index, name, isActive, isBound in
            try MCPBindContextTabSummary(
                contextID: fixtureID(index),
                name: name,
                workspaceID: discovery.id,
                workspaceName: discovery.name,
                isActive: isActive,
                isBound: isBound,
                repoPaths: ["/tmp/rp-discovery"]
            )
        }
        let other = try MCPBindContextWorkspaceSummary(id: fixtureID(11), name: "Other")
        let otherTab = try MCPBindContextTabSummary(
            contextID: fixtureID(5),
            name: "Main",
            workspaceID: other.id,
            workspaceName: other.name,
            isActive: true,
            isBound: false,
            repoPaths: ["/tmp/rp-other"]
        )
        return try [
            MCPBindContextWindowSummary(
                windowID: 3,
                isCurrentWindow: true,
                workspace: discovery,
                activeContextID: fixtureID(1),
                tabs: discoveryTabs
            ),
            MCPBindContextWindowSummary(
                windowID: 5,
                isCurrentWindow: false,
                workspace: other,
                activeContextID: fixtureID(5),
                tabs: [otherTab]
            )
        ]
    }

    private func fixtureID(_ index: Int) throws -> UUID {
        try XCTUnwrap(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012ld", index)))
    }

    private func windowsBlock(of text: String) throws -> String {
        let start = try XCTUnwrap(text.range(of: "### Windows"), text)
        let end = try XCTUnwrap(text.range(of: "\n\n### Next Steps"), text)
        return String(text[start.lowerBound ..< end.lowerBound])
    }

    private func nextSteps(of text: String) throws -> String {
        let start = try XCTUnwrap(text.range(of: "### Next Steps"), text)
        return String(text[start.lowerBound...])
    }
}
