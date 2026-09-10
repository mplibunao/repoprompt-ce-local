import Foundation
import MCP

/// Renders a caught error for MCP clients and diagnostics. `localizedDescription` on a bare Swift
/// error collapses to "The operation couldn't be completed", which hides the reason a tool failed;
/// `LocalizedError.errorDescription` carries it.
func mcpErrorRenderingText(_ error: Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? "\(error)"
}

/// Convenience helpers for building success or error replies from any tool.
extension CallTool.Result {
    /// Builds an error result with the supplied message.
    static func err(_ message: String) -> Self {
        .init(content: [MCP.Tool.Content.text(message)], isError: true)
    }

    /// Builds a plain-text success result.  Default text is "ok".
    static func ok(text: String = "ok") -> Self {
        .init(content: [MCP.Tool.Content.text(text)], isError: false)
    }
}
