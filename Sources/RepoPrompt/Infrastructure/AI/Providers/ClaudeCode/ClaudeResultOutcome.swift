import Foundation

/// How a Claude Code stream-json `result` payload ended its turn.
///
/// Agent Mode's session controller and the headless provider that runs Context Builder discovery both
/// classify `result` payloads here, so they agree on which turns failed and which were cancelled.
enum ClaudeResultOutcome: Equatable {
    case completed
    case cancelled
    case failed

    /// A cancellation signal in the subtype, the stop reason, or the errors outranks the error flags,
    /// because an interrupted turn also reports `is_error` and an error subtype.
    init(resultPayload payload: [String: Any], stopReasonHint: String? = nil) {
        let subtype = ((payload["subtype"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let stopReason = ((payload["stop_reason"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if Self.isCancellationSignal(subtype)
            || Self.isCancellationSignal(stopReason)
            || Self.isCancellationSignal(stopReasonHint)
        {
            self = .cancelled
            return
        }
        if let streamEvent = payload["event"] as? [String: Any],
           let delta = streamEvent["delta"] as? [String: Any],
           let nestedStopReason = delta["stop_reason"] as? String,
           Self.isCancellationSignal(nestedStopReason)
        {
            self = .cancelled
            return
        }

        let errors = Self.errorMessages(in: payload)
        if errors.contains(where: { Self.isCancellationSignal($0) }) {
            self = .cancelled
            return
        }

        if (payload["is_error"] as? Bool) == true
            || subtype.contains("error")
            || !errors.isEmpty
        {
            self = .failed
            return
        }
        self = .completed
    }

    /// The non-empty messages in the payload's `errors` array: string entries, and the `message` or
    /// `error` field of object entries.
    static func errorMessages(in payload: [String: Any]) -> [String] {
        guard let errors = payload["errors"] as? [Any] else { return [] }
        return errors.compactMap { entry in
            switch entry {
            case let text as String:
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            case let object as [String: Any]:
                let message = (object["message"] as? String) ?? (object["error"] as? String)
                let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return trimmed.isEmpty ? nil : trimmed
            default:
                return nil
            }
        }
    }

    private static func isCancellationSignal(_ value: String?) -> Bool {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty
        else {
            return false
        }
        return value.contains("interrupt")
            || value.contains("cancel")
            || value.contains("aborted")
            || value.contains("request was aborted")
    }
}
