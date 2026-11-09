import SwiftUI

extension EnvironmentValues {
    /// Whether the hosting window is visible, not miniaturized or fully occluded, and its app is not hidden.
    /// Presentation-only; it must never gate execution, persistence, or model publication.
    /// Defaults to `true` for views outside a tracked window.
    @Entry var windowIsPresentationVisible: Bool = true
}
