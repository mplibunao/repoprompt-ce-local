@testable import RepoPromptApp

enum ACPModelParameterTestSupport {
    /// A definition whose choice names are the capitalized wire values and whose current value
    /// is the first choice.
    static func definition(
        kind: ACPModelParameterKind,
        configID: String,
        values: [String]
    ) -> ACPModelParameterDefinition {
        ACPModelParameterDefinition(
            kind: kind,
            configID: configID,
            displayName: configID.capitalized,
            choices: values.map { ACPModelParameterChoice(rawValue: $0, displayName: $0.capitalized) },
            currentValueRaw: values[0]
        )
    }

    /// The composer's live controls for a model, as (kind, displayed choice) pairs: one per
    /// advertised kind whose definition yields a choice under the composer's rule, including
    /// Cursor's fallback to the advertised current value. Saved-only recovery controls are
    /// excluded.
    static func composerChoices(
        providerID: ACPProviderID,
        selectedModelRaw: String,
        persistedSelections: [ACPModelParameterSelection]
    ) -> [(kind: ACPModelParameterKind, choice: ACPModelParameterChoice)] {
        ACPModelParameterResolver.pinControls(
            providerID: providerID,
            selectedModelRaw: selectedModelRaw,
            parameterSet: ACPModelParameterResolver.parameterSet(
                providerID: providerID,
                selectedModelRaw: selectedModelRaw
            ),
            persistedSelections: persistedSelections
        ).compactMap { control in
            guard let definition = control.definition,
                  let choice = ACPModelParameterResolver.composerSelectedChoice(
                      definition: definition,
                      saved: control.saved,
                      providerID: providerID
                  )
            else { return nil }
            return (control.kind, choice)
        }
    }

    /// A window that starts no live provider catalog subscription. Marking a provider connected
    /// on a default window starts a background catalog discovery (Cursor, for example) whose
    /// save rewrites the persisted ACP catalogs shared by every test in the process, after the
    /// test that caused it has finished. Callers that need provider validation complete it
    /// explicitly.
    @MainActor
    static func makeWindowWithoutLiveProviderCatalogs() -> WindowState {
        let window = WindowState(codexModelPollingService: .shared, loadStoredAPISettingsDataOnInit: false)
        window.apiSettingsViewModel.prepareForWindowClose()
        return window
    }
}
