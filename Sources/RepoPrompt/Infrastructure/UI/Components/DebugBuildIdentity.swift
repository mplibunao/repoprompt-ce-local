import SwiftUI

/// In-window identity for RepoPrompt CE debug builds.
///
/// The debug bundle differs from production in the Dock and Finder (display name, executable,
/// and `AppBundle/AppIconDebug.icns`). These cues carry the icon's blue "DEBUG" badge color into
/// the window chrome so a debug window is not mistaken for a production one, while transcript,
/// code, and syntax colors stay untouched. Release builds compile every view-level cue out.
enum DebugBuildIdentity {
    static var isEnabled: Bool {
        #if DEBUG
            true
        #else
            false
        #endif
    }

    /// sRGB components of the blue "DEBUG" badge on `AppBundle/AppIconDebug.icns` (#014FF2).
    static let accentSRGB: (red: Double, green: Double, blue: Double) = (1.0 / 255.0, 79.0 / 255.0, 242.0 / 255.0)

    static let accentColor = Color(
        .sRGB,
        red: accentSRGB.red,
        green: accentSRGB.green,
        blue: accentSRGB.blue,
        opacity: 1
    )

    static let badgeTitle = "DEBUG"
    static let accessibilityDescription = "RepoPrompt CE debug build"

    /// Height of the accent rule along the top content edge, directly below the window chrome.
    static let windowEdgeRuleHeight: CGFloat = 2

    /// Low enough that the composer ring reads as chrome rather than an alert.
    static let composerRingOpacity: Double = 0.45

    /// Whether the composer draws the debug ring. An explicit composer highlight, such as the
    /// one on an MCP-controlled tab, always takes precedence.
    static func showsComposerRing(explicitHighlight: Color?) -> Bool {
        isEnabled && explicitHighlight == nil
    }
}

#if DEBUG
    /// Compact toolbar badge mirroring the debug app icon's "DEBUG" badge.
    struct DebugBuildToolbarBadge: View {
        var body: some View {
            Text(DebugBuildIdentity.badgeTitle)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(0.6)
                .foregroundStyle(Color.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(DebugBuildIdentity.accentColor))
                .fixedSize()
                .hoverTooltip(DebugBuildIdentity.accessibilityDescription, .bottomRight)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(DebugBuildIdentity.accessibilityDescription)
        }
    }
#endif

extension View {
    /// Draws the debug accent rule along the top content edge without taking layout height,
    /// hit testing, or accessibility focus. Release builds return `self` unchanged.
    @ViewBuilder
    func debugBuildWindowEdge() -> some View {
        #if DEBUG
            overlay(alignment: .top) {
                DebugBuildIdentity.accentColor
                    .frame(height: DebugBuildIdentity.windowEdgeRuleHeight)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        #else
            self
        #endif
    }
}
