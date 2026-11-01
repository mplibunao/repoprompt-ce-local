import Foundation

/// Persisted file-selection surface for workspace compose-tab state.
enum FilesTab: String, Codable {
    case selected = "Selected Files"
    case context = "Context Builder"

    private static let legacyApplyXMLRawValue = "Apply XML"

    init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        if rawValue == Self.legacyApplyXMLRawValue {
            self = .context
            return
        }
        self = FilesTab(rawValue: rawValue) ?? .context
    }
}

@MainActor
extension FilesTab {
    /// Default tab for CE builds.
    static var defaultTab: FilesTab {
        .context
    }
}
