# MCP tool descriptions

Different audiences read a tool's text, and each gets it through a different path. This note says which text reaches whom and how to write it. `bind_context` is the worked example.

## Who reads what

**Agents, through `tools/list`.** For a tool that has a canonical definition in `MCPDomainCanonicalToolDefinitions`, that definition is the source of both the description and the schema an MCP client receives, and no registration text reaches a client; the app's `tools/list` handler projects each schema, keeping `working_dirs` only on `bind_context` and `context_id` only on `bind_context`, `oracle_utils`, and `context_builder`. `Tool.domainBinding()` replaces a registration's own metadata with the canonical definition of the same name and keeps the registration's metadata when there is none, `AppDomainRuntimeComposition` registers that binding in `MCPDomainToolRegistry`, and the `tools/list` handler in `ServerNetworkManager` serves what `MCPDomainHost.advertisedCatalog` returns from that registry. `DirectHeadlessMCPService` serves the same definitions for `--backend headless`. A client pays for this text on each `tools/list` that advertises the tool to it. Both backends withhold a tool that the client's policy hides, as a restricted capability does, and the app also withholds a tool that is switched off in Settings.

**A person, in Settings.** `ToolAvailabilityStore` copies the `description` of each `Tool` it is given into a `ToolSummary`, and `MCPToolsSettingsView` shows it verbatim, without Markdown, clamped to three lines with an expander. `AppDomainRuntimeComposition` hands the store the raw registrations of the application-scope tools (`bind_context`, `manage_workspaces`, `app_settings`), so their Settings row shows the description written at the registration site, such as `WindowRoutingService.bindContextSettingsDescription`. Window-scoped tools are canonicalized by `MCPAppToolCatalogRegistration` before they reach the store, so their row shows the canonical text.

**Agents, after a call.** An agent reads output hints and routing errors when a call returns them: the Next Steps that `ToolOutputFormatter` appends to a `bind_context` list, and the guidance in `ServerNetworkManager.multiWindowSelectionGuidance` and `MCPServerViewModel.tabContextRoutingErrorMessage`.

**A person, at a terminal.** The CLI help in `RepoPromptMCP` (`printUsage` and the `MCPCommandRunner` help).

**Not managed Agent Mode sessions, for `bind_context`.** `MCPDomainToolCatalog` gives `bind_context` the `workspaceMutate` capability, every Agent Mode profile in `MCPClientToolPolicyCatalog` restricts that capability, and `advertisedCatalog` hides restricted tools. Its text costs external clients only.

## Principles

1. **Write for the audience.** An agent needs what changes its next call. A person in Settings needs to understand what enabling the tool lets a client do. Identical wording across the two is not a goal.
2. **State each parameter fact once, in the schema.** A canonical description is paid for on every `tools/list` that advertises the tool. Shapes, matching rules, side effects, and per-operation meaning of a parameter belong in its property description. The tool description carries only what the schema cannot: what the tool is for, when to call which operation, and how backends differ. A description placed beside `anyOf` does not survive the `JSONSchema` projection in `Tool`, so a union carries its description on a branch.
3. **Same facts on every surface.** The canonical text, the Settings text, hints, errors, and CLI help must agree in meaning. When a fact changes, change every surface that states it.
4. **Discovery guidance is conditional and progressive.** Use what is known, list to find what is not, and expand only when needed. For `bind_context`: a known `context_id` or full set of `working_dirs` is bound directly; `list` finds an unknown target; one window is listed in full only when the wanted tab is missing from the compact multi-window result.
5. **Examples are plain JSON arguments objects.** An example is the value of `arguments` in a `tools/call`, such as `{"op":"list","window_id":<window_id>}`, with explicit placeholders like `<window_id>` and `<context_id>`. It is not an encoded string and not a CLI command.
6. **State a backend-specific fact once.** Say where the app and standalone headless differ in one place per surface, not on every sentence it touches.

## Changing a definition

Follow [Canonical MCP schema and bind_context discovery](../testing.md#canonical-mcp-schema-and-bind_context-discovery) for snapshot regeneration, the catalog fingerprint, the covering suites, and live validation.
