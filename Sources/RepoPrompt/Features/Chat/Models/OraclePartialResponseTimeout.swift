import Foundation

struct OraclePartialResponseTimeout: Equatable {
    enum Reason: Equatable {
        case inactivity(seconds: TimeInterval)
        case overall(seconds: TimeInterval)
    }

    let partialText: String
    let reason: Reason
    let errorMessage: String

    var marker: String {
        switch reason {
        case let .inactivity(seconds):
            "[RepoPrompt: response ended after \(Self.formatSeconds(seconds)) s without stream activity; content above is partial]"
        case let .overall(seconds):
            "[RepoPrompt: response ended after \(Self.formatSeconds(seconds)) s without completion; content above is partial]"
        }
    }

    var responseText: String {
        // A timeout is partial success once content has streamed, so preserve the received bytes verbatim.
        if partialText.hasSuffix("\n\n") {
            return partialText + marker
        }
        if partialText.hasSuffix("\n") {
            return partialText + "\n" + marker
        }
        guard !partialText.isEmpty else { return marker }
        return partialText + "\n\n" + marker
    }

    private static func formatSeconds(_ seconds: TimeInterval) -> String {
        let rounded = seconds.rounded()
        if rounded == seconds {
            return String(Int(rounded))
        }
        return String(format: "%.1f", seconds)
    }
}
