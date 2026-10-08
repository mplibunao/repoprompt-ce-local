# MCP progress for long-running tools

RepoPrompt CE reports observable progress for long-running Context Builder and
Oracle work without changing the final tool result or cancellation contract.

## Standard MCP clients

A client requests progress by including a unique `progressToken` in the
`_meta` object of its `tools/call` request:

```json
{
  "jsonrpc": "2.0",
  "id": 42,
  "method": "tools/call",
  "params": {
    "name": "context_builder",
    "arguments": {
      "instructions": "Trace the authentication path"
    },
    "_meta": {
      "progressToken": "context-builder-42"
    }
  }
}
```

While the request is running, RepoPrompt CE sends standard
`notifications/progress` notifications with the same token. The `progress`
field is a monotonically increasing event sequence, not a percentage. The
`total` field is omitted because discovery and model generation do not have a
reliable fixed work total.

This follows the MCP
[progress utility](https://modelcontextprotocol.io/specification/2025-11-25/basic/utilities/progress):
the receiver echoes the caller's token and keeps progress values increasing for
that request.

Context Builder messages include the active stage and detailed phase, such as
model resolution, payload packaging, response streaming, tab-context commit,
or workspace persistence. Long phases also emit heartbeats.

Nested provider startup and routing use these ordered `discovering` phases:

- `provider_process_starting`
- `waiting_for_child_connection`
- `child_connection_observed`
- `waiting_for_routing`
- `routing_confirmed`
- `routing_timeout_before_connection`
- `routing_timeout_after_connection`

The top-level `starting` stage is reserved for setting up the Context Builder
tool call itself. `provider_process_starting` remains under `discovering`
because it starts the nested discovery provider after tool setup is complete;
the word “starting” in the phase name does not move it back into the tool's
top-level setup stage.

`child_connection_observed` means the connection matched the exact run-owned
client-name/PID policy. It is intentionally sticky: if route installation later
rolls back, the connection was still observed. The run keeps waiting until the
route commits, the run loses ownership of its expected connection, the provider
finishes without opening that connection, or the run is cancelled.
A connection refused for joining an established run by process ancestry alone
(`expected_pid_without_pending_policy`) never matched a run-owned policy, so it
is neither an observed child connection nor a routed one: it emits neither
`child_connection_observed` nor `routing_confirmed`, and the waiting run
continues as if that connection had not arrived.
The two `routing_timeout_*` phases apply only to callers that select a bounded
routing wait. A Context Builder run's routing wait has no deadline, so its runs
don't report them. In a bounded wait, a deadline that expires after a
connection was observed is reported as `routing_timeout_after_connection`, and
an explicit routing failure or cancellation isn't reported as a timeout.
These phases are observations only and do not change provider launch, routing,
timeout, cleanup, cancellation, or final-result behavior.

Clients that omit `_meta.progressToken` receive the same final result but do not
receive standard progress notifications. A host may also choose not to render
notifications it receives.

## Context Builder startup waits

A Context Builder run waits on two things it can't finish itself: the window's
MCP tools becoming ready, and its provider's MCP connection being routed to the
run. Neither wait has a time limit.

Runs that start while the window's MCP tools are still being enabled join one
readiness wait. A cancelled run leaves the wait alone, and the wait keeps
serving the other runs.

The routing wait starts when the run starts its provider. It ends only when the
route commits, the run loses ownership of its expected connection, the provider
finishes without opening that connection, or the run is cancelled.

A window whose MCP tools never become ready, or a provider that never opens its
connection, keeps the run waiting until the run is cancelled or a failure is
reported. A startup that hangs shows up as a run that keeps waiting, not as an
error.

## Context Builder refusals

A tab runs one Context Builder operation at a time: a discovery run together
with the follow-up it owns. Runs on different tabs of one window proceed
together. A call for an occupied tab is refused at once. Nothing is queued or
retried.

| Situation | Result of the `context_builder` call |
|---|---|
| The tab already has a Context Builder operation in this window | Error `Context Builder is already running for this tab.` |
| Another window that shows the same workspace holds the same tab | The same error |
| The tab or its window is closing when the call claims the tab | Error `Tool execution was cancelled.` |
| The call loses its tab after it was admitted | The same cancellation, before the call's next step |
| A provider restarts its process inside a run and RepoPrompt CE can't prepare a connection policy for the new process | The run fails with `RepoPrompt could not prepare this run's MCP connection policy for a restarted agent process, so the process was not started.` |

A call refused for an occupied tab changes nothing. It binds no caller
connection and drains no read-file auto-selection, and it starts no provider
and records no run. The operation that holds the tab keeps its state and its
log. A cancelled run reports its cancellation, never the restart failure.

One caller connection reaches two tabs only by rebinding between its
requests. Each request keeps the tab it was admitted for, and a later rebind
redirects neither an earlier request nor its result.

## Reading Context Builder phases and errors

A run's state is `running` from admission. Its lifecycle stage stays
`preparingRuntime` while it joins the window's MCP readiness, installs its
connection policy, and asks its provider to start. `running` with stage
`preparingRuntime` isn't evidence that a provider process exists. Neither is
`provider_process_starting`, which the run reports before it asks the provider
to start. `child_connection_observed` is the first phase that shows a live
provider process: its MCP helper connected under the run's policy.

A startup failure names its cause in the run's error text:

| Error text begins with | Meaning |
|---|---|
| `Failed to start MCP server:` | The window's MCP readiness failed. The rest of the text is the cause. |
| `Failed to prepare MCP connection policy:` | The run couldn't install its connection policy. The rest of the text is the cause. |
| `mcp_routing_failed:` | The run lost ownership of its expected connection before routing committed |
| `mcp_completed_without_route:` | The provider finished before it opened the expected MCP connection |

A cancelled run reports its cancellation, not one of these errors.

A detached tool call owned by one run can make another run's tool call in the
same window return `tool_execution_structure_settlement_busy`. That response
is back-pressure on the one call. It doesn't cancel the other run, change its
routing, or change its prompt or selection.

## `rpce-cli` behavior

Non-interactive `rpce-cli -e` calls request a unique standard progress token and
print progress messages to stderr:

```text
[progress] context_builder [discovering]: Running Context Builder agent...
[progress] context_builder [discovering]: Still in tab-context commit ...
[progress] context_builder [generating]: Oracle response streaming started ...
```

Stdout remains valid MCP or command output. RepoPrompt's older
`repoprompt/control/progress` notification remains available as a compatibility
fallback when a bundled CLI talks to an older app build.

Progress is advisory. A dropped notification does not fail the tool call.
Cancelling the request still uses MCP request cancellation and stops the
underlying Context Builder work through the existing lifecycle path.
The server invalidates request progress before returning the final result and
drains notifications already accepted for delivery, so heartbeat, soft-bound,
and timeline delivery tasks cannot emit against a completed request.
