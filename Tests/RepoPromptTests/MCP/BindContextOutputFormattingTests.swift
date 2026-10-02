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
        XCTAssertTrue(try nextSteps(of: text).contains("`{\"op\":\"list\",\"window_id\":3}`"), text)
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
        // Every tab is already listed, so the window filter is not suggested again.
        XCTAssertFalse(try nextSteps(of: text).contains("\"op\":\"list\""), text)
    }

    func testHintedArgumentsMatchProjectedCanonicalSchema() throws {
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
        let hints = try [
            nextSteps(of: formattedList(windowID: nil, windows: twoWindows())),
            ServerNetworkManager.multiWindowSelectionGuidance(),
            canonical.description
        ]
        let listedContextID = try fixtureID(2).uuidString
        for hint in hints {
            // Every backticked JSON object is a hinted call, whichever key it starts with.
            let examples = try matches(of: #"`(\{[^`]*\})`"#, in: hint, group: 1)
            XCTAssertFalse(examples.isEmpty, hint)
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
            XCTAssertFalse(hint.contains("_windowID"), hint)
            XCTAssertFalse(hint.contains("whichever tab"), hint)
            XCTAssertFalse(hint.localizedCaseInsensitiveContains("window affinity"), hint)
        }
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

    private func matches(of pattern: String, in text: String, group: Int = 0) throws -> [String] {
        let regex = try NSRegularExpression(pattern: pattern)
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range(at: group), in: text).map { String(text[$0]) }
        }
    }
}
