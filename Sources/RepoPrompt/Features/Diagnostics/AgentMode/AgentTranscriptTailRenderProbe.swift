#if DEBUG
    import AppKit
    import SwiftUI

    /// DEBUG-only render instrumentation for Agent Mode transcript rows and the Markdown and native
    /// text views beneath them.
    ///
    /// A local measurement harness or test installs `sink` to observe block builds, bubble bodies,
    /// runtime-footer evaluations, Markdown compiles, and native text-view boundaries. The sink owns
    /// attribution of native views to rows and keeps event text and native views in memory; it must
    /// never write them to logs or MCP output.
    ///
    /// When `AgentModePerfDiagnostics` is enabled, bubble bodies, Markdown compiles, and native updates
    /// and replacements also increment aggregate per-window counters, which `agent_perf_metrics`
    /// reports. When neither consumer is enabled, no event is built and nothing is recorded.
    @MainActor
    enum AgentTranscriptTailRenderProbe {
        enum NativeBoundary: String {
            case make, update, replacement, size, ensureLayout, draw
        }

        enum Event {
            case block(String)
            case body(UUID, String)
            case footer(UUID?, String)
            case native(NativeBoundary, UUID?, CodeBlockTextView)
            case markdownCompile(UUID?)
        }

        /// Aggregate counters forwarded to `AgentModePerfDiagnostics`, one set per window.
        enum WindowCounter: String {
            case bubbleBody, markdownCompile, nativeUpdate, nativeReplacement
        }

        static var sink: ((Event) -> Void)?

        /// Sends an event to the sink. The event is built only when a sink is installed.
        static func record(_ event: @autoclosure () -> Event) {
            guard let sink else { return }
            sink(event())
        }

        /// Sends an event to the sink and increments the window's aggregate counter when perf
        /// diagnostics are enabled. The event is built only when a sink is installed.
        static func record(_ event: @autoclosure () -> Event, counting counter: WindowCounter, windowID: Int?) {
            if let sink {
                sink(event())
            }
            if AgentModePerfDiagnostics.isEnabled {
                AgentModePerfDiagnostics.increment(counterKey(counter, windowID: windowID))
            }
        }

        static func counterKey(_ counter: WindowCounter, windowID: Int?) -> String {
            let window = windowID.map(String.init) ?? "unscoped"
            return "ui.transcriptRender.window.\(window).\(counter.rawValue)"
        }
    }

    extension EnvironmentValues {
        /// The transcript row whose subtree is rendering, used to attribute native text views to rows.
        @Entry var agentTranscriptProbeRowID: UUID?
        /// The window whose subtree is rendering, used to name the forwarded per-window counters.
        @Entry var agentTranscriptProbeWindowID: Int?
    }
#endif
