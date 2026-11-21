import MCP

/// The capabilities the app's bootstrap MCP server declares in its `initialize` result.
///
/// The app builds its server from this value, and the helper's offline responder encodes the same
/// value. After the helper attaches to the app it replays the client's `initialize` and compares
/// the app's `capabilities` and `protocolVersion` with what the client already received, so the two
/// must never drift apart.
public enum MCPAppServerCapabilities {
    public static let value = MCP.Server.Capabilities(
        prompts: .init(listChanged: false),
        resources: .init(subscribe: false, listChanged: false),
        tools: .init(listChanged: true)
    )
}
