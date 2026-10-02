@testable import RepoPromptApp
import SwiftUI
import XCTest

final class DebugBuildIdentityTests: XCTestCase {
    func testInWindowIdentityFollowsTheBuildConfiguration() {
        #if DEBUG
            XCTAssertTrue(DebugBuildIdentity.isEnabled)
        #else
            XCTAssertFalse(DebugBuildIdentity.isEnabled)
        #endif
    }

    func testBadgeTextMeetsWCAGAAContrastOnAccentFill() {
        let accent = DebugBuildIdentity.accentSRGB
        let accentLuminance = Self.relativeLuminance(red: accent.red, green: accent.green, blue: accent.blue)
        let whiteLuminance = 1.0
        let contrast = (whiteLuminance + 0.05) / (accentLuminance + 0.05)

        // The badge draws small bold white text on the accent capsule; hold the normal-text AA bar.
        XCTAssertGreaterThanOrEqual(contrast, 4.5, "DEBUG badge contrast \(contrast) is below WCAG AA")
    }

    func testBadgeAccessibilityLabelDescribesTheBuildRatherThanRepeatingTheBadge() {
        let label = DebugBuildIdentity.accessibilityDescription

        XCTAssertNotEqual(label, DebugBuildIdentity.badgeTitle)
        XCTAssertTrue(label.localizedCaseInsensitiveContains("RepoPrompt CE"))
        XCTAssertTrue(label.localizedCaseInsensitiveContains("debug build"))
    }

    func testComposerRingYieldsToAnExplicitHighlight() {
        XCTAssertFalse(DebugBuildIdentity.showsComposerRing(explicitHighlight: .orange))
        XCTAssertEqual(DebugBuildIdentity.showsComposerRing(explicitHighlight: nil), DebugBuildIdentity.isEnabled)
    }

    private static func relativeLuminance(red: Double, green: Double, blue: Double) -> Double {
        func linearize(_ component: Double) -> Double {
            component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linearize(red) + 0.7152 * linearize(green) + 0.0722 * linearize(blue)
    }
}
