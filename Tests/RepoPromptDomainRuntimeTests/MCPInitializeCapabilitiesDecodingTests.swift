import Foundation
import MCP
import XCTest

/// Codex's MCP client advertises a JSON-object experimental capability during `initialize`.
/// The pinned MCP SDK must decode it, or every Codex handshake with RepoPrompt fails.
final class MCPInitializeCapabilitiesDecodingTests: XCTestCase {
    func testInitializeRequestDecodesCodexObjectValuedExperimentalCapability() throws {
        let frame = Data("""
        {"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18",\
        "capabilities":{"experimental":{"codex/auth-change":{}},"elicitation":{"form":{},"url":{}}},\
        "clientInfo":{"name":"codex-mcp-client","title":"Codex","version":"0.156.1"}}}
        """.utf8)

        let request = try JSONDecoder().decode(Request<Initialize>.self, from: frame)

        XCTAssertEqual(request.method, Initialize.name)
        XCTAssertEqual(request.params.capabilities.experimental?["codex/auth-change"], .object([:]))
        XCTAssertEqual(request.params.clientInfo.name, "codex-mcp-client")
    }
}
