import SwiftUI

/// Passive renderer for one parameter pin (one kind) on the Settings, popover and Context
/// Builder surfaces, for any ACP provider.
///
/// It renders whenever there is something honest to show: an unambiguous advertised definition
/// **or** a saved pin. It never invents choices, never presents a provider default as if it
/// were a saved pin, and never hides a saved pin just because its metadata is currently
/// unavailable. Metadata arrival never writes settings; only a menu action emits a change.
struct ACPModelParameterPinChip: View {
    let control: ACPModelParameterPinControl
    let providerDisplayName: String
    /// Prefix the value with the parameter name, for rows that could otherwise be ambiguous.
    let showsParameterName: Bool
    let isEnabled: Bool
    let onChange: (ACPModelParameterPinChange) -> Void

    @ObservedObject private var fontScale = FontScaleManager.shared

    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    private var definition: ACPModelParameterDefinition? {
        control.definition
    }

    private var pinnedValueRaw: String? {
        control.saved?.valueRaw
    }

    private var parameterName: String {
        definition?.displayName ?? control.kind.recoveryDisplayName
    }

    /// The advertised choice the saved value resolves to, matched as the provider matches it.
    private var pinnedChoice: ACPModelParameterChoice? {
        pinnedValueRaw.flatMap { definition?.choice(matching: $0) }
    }

    /// The pinned choice's display name when available, else the saved raw value verbatim.
    /// Never substituted with the advertised current value.
    private var valueLabel: String {
        guard let pinnedValueRaw else { return Self.unpinnedLabel }
        return Self.choiceLabel(pinnedChoice?.displayName ?? pinnedValueRaw, providerDisplayName: providerDisplayName)
    }

    /// The label for "no saved value": the chip's unpinned state and the menu entry that clears.
    nonisolated static let unpinnedLabel = "Default"

    /// How a pinned value reads in the menu and on the chip. A provider may advertise its own
    /// value named "default" (OpenCode does), which is an explicit pin distinct from clearing;
    /// naming the provider keeps it from reading as the unpinned state.
    nonisolated static func choiceLabel(_ displayName: String, providerDisplayName: String) -> String {
        let collides = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(unpinnedLabel) == .orderedSame
        return collides ? "\(unpinnedLabel) (\(providerDisplayName))" : displayName
    }

    private var label: String {
        showsParameterName ? "\(parameterName): \(valueLabel)" : valueLabel
    }

    private var isSavedPinUnavailable: Bool {
        control.isSavedValueUnavailable
    }

    /// Hover text for the unpinned ("Default") state. "Default" is already overloaded elsewhere
    /// in this UI ("no model specified", base-variant submenus), so this state says what it
    /// resolves to: with a definition, the provider's current advertised value; without one,
    /// that the value is not yet discovered. Pure and static so it is unit-testable without a
    /// view host.
    static func defaultTooltip(
        definition: ACPModelParameterDefinition?,
        kind: ACPModelParameterKind,
        providerDisplayName: String
    ) -> String {
        let subject = "Default — \(providerDisplayName)'s current \(kind.tooltipNoun) for this model"
        guard let definition else {
            return "\(subject) (not yet discovered)"
        }
        let currentValue = definition.choice(matching: definition.currentValueRaw)?.displayName
            ?? definition.currentValueRaw
        return "\(subject): \(currentValue)"
    }

    private var tooltip: String {
        if isSavedPinUnavailable {
            return "Saved \(control.kind.savedValueNoun) \"\(valueLabel)\" is not currently advertised for this model."
        }
        guard pinnedValueRaw == nil else {
            return definition?.displayName ?? control.kind.savedValueTitle
        }
        return Self.defaultTooltip(
            definition: definition,
            kind: control.kind,
            providerDisplayName: providerDisplayName
        )
    }

    /// Mirrors the hover text: the unpinned state announces what Default resolves to, and a
    /// saved-but-unadvertised pin announces itself as unavailable.
    private var accessibilityValueText: String {
        if isSavedPinUnavailable {
            return "\(label), unavailable"
        }
        guard pinnedValueRaw == nil else { return label }
        return Self.defaultTooltip(
            definition: definition,
            kind: control.kind,
            providerDisplayName: providerDisplayName
        )
    }

    var body: some View {
        Menu {
            // "Not pinned" is a first-class state: choosing it clears this kind's pin only.
            Button {
                onChange(.clear(control.identity))
            } label: {
                HStack {
                    Text(Self.unpinnedLabel)
                    if pinnedValueRaw == nil {
                        Spacer()
                        Image(systemName: "checkmark")
                    }
                }
            }
            if let definition {
                // Every advertised choice renders, including a single-choice menu and a provider
                // wire value named "default", which is an explicit pin distinct from clearing.
                ForEach(definition.choices, id: \.rawValue) { choice in
                    Button {
                        onChange(.pinning(
                            choice,
                            of: definition,
                            providerID: control.providerID,
                            baseModelRaw: control.baseModelRaw
                        ))
                    } label: {
                        HStack {
                            Text(Self.choiceLabel(choice.displayName, providerDisplayName: providerDisplayName))
                            if pinnedChoice?.rawValue == choice.rawValue {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
        } label: {
            Text(label)
                .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                .foregroundColor(isSavedPinUnavailable ? .orange : .secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(4)
        }
        .menuStyle(.borderlessButton)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1.0 : 0.55)
        // Native AppKit-anchored help, not the custom hoverTooltip bubble: the custom
        // overlay window mispositions after its hosting view relayouts (it balloons in
        // height and drops to the bottom of the screen, worst for this chip's long Default
        // text), while native help is anchored by AppKit next to the control.
        // swiftlint:disable:next no_swiftui_help_modifier
        .help(tooltip)
        .accessibilityValue(Text(accessibilityValueText))
        .fixedSize()
    }
}
