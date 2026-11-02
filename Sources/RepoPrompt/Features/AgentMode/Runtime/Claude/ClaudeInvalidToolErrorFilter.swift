import Foundation

// SEARCH-HELPER: Claude, ToolUseError, NoSuchTool, InvalidTool, TranscriptFilter
/// Detects Claude Code `tool_use_error` results that report an unknown tool name.
///
/// Claude Code emits these when the model invokes a tool that isn't registered —
/// for example when it shortens `mcp__RepoPrompt__read_file` to `mcp__RepoPrompt`
/// (or omits the trailing tool segment for any MCP server). The CLI replies with:
///
/// ```
/// <tool_use_error>Error: No such tool available: <toolName></tool_use_error>
/// ```
///
/// The paired placeholder tool call plus this error add noise to the transcript
/// without giving the user any actionable information, so callers use this
/// filter to drop both rows.
///
/// Related:
/// - Producer (upstream): `claude-code/src/services/tools/toolExecution.ts`
/// - Sibling filter: `ClaudeAbortArtifactFilter`
/// - Consumer: `ClaudeAgentToolTrackingHandler.handleProviderToolResult`
enum ClaudeInvalidToolErrorFilter {
    /// Returns `true` when the given tool-result payload is a Claude
    /// "No such tool available" `tool_use_error` that should be suppressed from
    /// the transcript along with its placeholder tool call.
    ///
    /// - Parameters:
    ///   - resultText: Raw tool-result content emitted by the Claude stream.
    ///     Accepts either the bare `<tool_use_error>…</tool_use_error>` payload
    ///     or a JSON-wrapped variant whose fields contain it.
    ///   - isError: The `is_error` signal carried alongside the tool_result
    ///     block (when known). The filter still matches when `isError` is nil
    ///     so we don't miss results that flow in without the flag.
    static func isNoSuchToolAvailableError(
        resultText: String?,
        isError: Bool?
    ) -> Bool {
        guard isError != false,
              let text = resultText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else {
            return false
        }
        return containsNoSuchToolSignal(in: text)
    }

    private static func containsNoSuchToolSignal(in text: String) -> Bool {
        // Match the exact wrapper emitted by Claude Code's toolExecution.ts
        // (case-insensitive so that upstream formatting drift doesn't break us,
        // but require both the opening + closing tag plus the specific phrase
        // so ambiguous error bodies can't accidentally trip the filter).
        let lowered = text.lowercased()
        guard lowered.contains("<tool_use_error>"), lowered.contains("</tool_use_error>") else { return false }
        return lowered.contains("no such tool available")
    }
}
