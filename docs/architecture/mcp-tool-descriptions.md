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
2. **State each parameter fact once, in the schema.** Put shapes, matching rules, side effects, and per-operation meanings in property descriptions; omit descriptions that only repeat the schema, such as operation names already listed in an enum. The tool description covers only purpose, operation choice, and backend differences: clients pay for it on every `tools/list` that advertises the tool. Because `Tool`'s `JSONSchema` projection drops descriptions beside `anyOf`, place the union's description on one branch and cover every form.
3. **Same facts on every surface.** The canonical text, the Settings text, hints, errors, and CLI help must agree in meaning. When a fact changes, change every surface that states it.
4. **Discovery guidance is conditional and progressive.** Use what is known, list to find what is not, and expand only when needed, and put each step where it becomes useful. For `bind_context`, the canonical description tells clients to bind a known `context_id` or `working_dirs` directly and list only to find a target. Listing one window in full applies only when a wanted tab is missing from a compact multi-window list, so that step and the worked JSON examples stay in the list's Next Steps and the multi-window routing error: clients pay for canonical text on each `tools/list` that advertises the tool and read a hint only when it applies.
5. **Examples are plain JSON arguments objects.** An example is the value of `arguments` in a `tools/call`, such as `{"op":"list","window_id":<window_id>}`, with explicit placeholders like `<window_id>` and `<context_id>`. It is not an encoded string and not a CLI command.
6. **State a backend-specific fact once.** Say where the app and standalone headless differ in one place per surface, not on every sentence it touches.

## Changing a definition

Follow [Canonical MCP schema and bind_context discovery](../testing.md#canonical-mcp-schema-and-bind_context-discovery) for snapshot regeneration, the catalog fingerprint, the covering suites, and live validation.

## Pull request descriptions

A pull request that changes an agent-facing tool description, schema, or hint carries two things in its description by default: a before/after size comparison and a short list of where to review.

### Size comparison

The comparison shows a reviewer what the change costs each client that receives the text. It says:

- **What each row is and who reads it.** The whole advertised entry is one tool's object in `tools/list` as a client receives it: the name, the description, the input schema, and every other field serialized with them (for `bind_context`, the annotations), including the JSON keys and punctuation. The description and the input schema are parts of that entry, shown as their own rows so a reader can see which part moved. They are not further totals, and they do not add up to the entry, because the entry also holds the other fields and the JSON around them, and JSON escapes the quotes and newlines inside the description. A Settings description that differs from the canonical one, as the one for `bind_context` does, is its own row: a person reads it, and it is never sent to an agent.
- **The unit.** Characters and whitespace-separated words are not tokens. Call a number a token count only when a tokenizer produced it, and then name the tokenizer and the model.
- **The method.** Name the revisions compared and how the text was serialized, such as compact JSON for the entry and the schema.
- **What moved and why.** Explain each meaningful increase or decrease and what an agent gains or loses for it. A smaller entry that drops a fact an agent needs is a regression: compactness comes after correctness.

When only a hint or an error changes, compare that output text. The entry did not change, so the comparison does not present it as if it had.

### Where to review

List the paths a reviewer should open as plain repository-relative paths in code formatting, not as links. A reviewer opens a path in an editor or an agent session, where a link to a hosted page does not help. Say after each path what to look at there, with line numbers when they help.

For a tool with a canonical definition, start with `docs/spec/mcp-domain-canonical-tool-definitions.generated.json`: it holds the description and input schema that `tools/list` advertises, in readable form, so it is the place to review that text. Then list only the other surfaces the change touched: a Settings description, an output hint, a routing error, or CLI help. For a tool without a canonical definition, list the file that holds its registration. "Who reads what" says where each text lives.

Add a source file beside the snapshot only when its behaviour needs review or the snapshot does not show the change; `Sources/RepoPromptDomainRuntime/MCPDomainCanonicalToolDefinitions.swift` is the source the snapshot is generated from, so listing both asks for one review twice.
