import AppKit

// MARK: – Delegate ----------------------------------------------------------

/// Very thin delegate that receives high-level mention events. Implemented
/// by `MentionCoordinator` which owns all heavy logic (search, overlay UI,
/// folder navigation, etc.).
@MainActor
protocol MentionTextViewDelegate: AnyObject {
    func mentionStarted(at caret: NSRect)
    func mentionQueryChanged(_ query: String, parent: MentionSuggestion?)
    func mentionNavigate(_ cmd: MentionNavigationCommand)
    func mentionAccept()
    func mentionAbort()
    func tokenRemoved(_ payload: MentionTokenPayload)
}

/// Arrow / esc navigation coming from the text-view.
enum MentionNavigationCommand { case up, down, left, right }

/// ---------------------------------------------------------------------------
/// NSTextView subclass that *only* detects "@ …" ranges and converts accepted
/// suggestions into attributed tokens. All expensive work has been moved out
/// into `MentionCoordinator`.
@MainActor
final class MentionTextView: NSTextView {
    // MARK: – External delegate

    weak var mentionDelegate: MentionTextViewDelegate?

    // MARK: – Mention session state (local only)

    private var mentionStartLocation: Int?

    // Track teardown so we never "repair" a view that's leaving the hierarchy.
    private var isTearingDown: Bool = false
    private var isComposingText: Bool {
        hasMarkedText()
    }

    // MARK: – TextKit safety / repair --------------------------------------

    /// Repairs TextKit invariants for this text view:
    /// - LayoutManager must include this view's textContainer
    /// - LayoutManager must not keep *other* containers that still reference this text view
    /// This avoids `glyphRangeForTextContainer:` crashes AND prevents multi-container drift.
    func repairTextKitIfNeeded() {
        // If we're not in a window (or are being removed), don't mutate TextKit internals.
        guard window != nil, !isTearingDown, let lm = layoutManager, let container = textContainer else { return }

        // 1) Ensure our container is registered.
        if !lm.textContainers.contains(where: { $0 === container }) {
            lm.addTextContainer(container)
        }

        // 2) Ensure the container points back to this view.
        if container.textView !== self {
            container.textView = self
        }

        let containers = lm.textContainers
        let extras = containers.enumerated().filter { _, c in
            c !== container && c.textView === self
        }
        guard !extras.isEmpty else { return }

        // 3) Only remove extra containers when it's safe (not first responder).
        let canRemoveExtras = (window?.firstResponder !== self)
        if canRemoveExtras {
            for (idx, _) in extras.reversed() {
                lm.removeTextContainer(at: idx)
            }
        } else {
            // Detach the view pointer to avoid container detachment crashes mid-command.
            for (_, c) in extras {
                c.textView = nil
            }
        }
    }

    // MARK: – Teardown

    func beginTeardown() {
        isTearingDown = true
        endMentionSession()
    }

    // MARK: – First-click always focuses the text view

    override func mouseDown(with event: NSEvent) {
        if window?.firstResponder !== self {
            window?.makeFirstResponder(self)
        }
        super.mouseDown(with: event)
    }

    // MARK: – Key handling ---------------------------------------------------

    override func keyDown(with event: NSEvent) {
        guard window != nil, !isTearingDown else { return }
        if isComposingText {
            super.keyDown(with: event)
            return
        }

        guard let chars = event.characters else {
            super.keyDown(with: event)
            return
        }

        // Detect the beginning "@"
        if chars == "@" {
            beginMentionSession()
            super.keyDown(with: event)
            let selection = clampSelectionToCurrentString()
            guard selection.length == 0,
                  let start = clampedMentionStartLocation(),
                  selection.location > start
            else {
                resetTransientEditingState()
                return
            }
            notifyCaretPosition()
            return
        }

        // If a mention session is active, refine or terminate it
        if let _ = mentionStartLocation {
            // ----------------------------------------------------------------
            // Navigation keys that should be forwarded to the delegate
            // ----------------------------------------------------------------
            switch event.keyCode {
            case 53: // esc
                mentionDelegate?.mentionAbort()
                endMentionSession()
                return
            case 125: // ↓
                mentionDelegate?.mentionNavigate(.down)
                return
            case 126: // ↑
                mentionDelegate?.mentionNavigate(.up)
                return
            case 123: // ←
                mentionDelegate?.mentionNavigate(.left)
                return
            case 124: // →
                mentionDelegate?.mentionNavigate(.right)
                return
            case 36, 76: // return / enter
                mentionDelegate?.mentionAccept()
                return
            default:
                break
            }

            // Regular character or deletion ⇒ update query
            super.keyDown(with: event)

            let selection = clampSelectionToCurrentString()
            guard selection.length == 0,
                  let start = clampedMentionStartLocation(),
                  selection.location > start
            else {
                resetTransientEditingState()
                return
            }
            mentionDelegate?.mentionQueryChanged(queryString(), parent: nil)
            return
        }

        super.keyDown(with: event)
    }

    // MARK: – Command handling ----------------------------------------------

    override func doCommand(by selector: Selector) {
        guard window != nil, !isTearingDown else { return }
        if isComposingText {
            super.doCommand(by: selector)
            return
        }
        clampSelectionToCurrentString()
        super.doCommand(by: selector)
    }

    // MARK: – Mention lifecycle ---------------------------------------------

    private func beginMentionSession() {
        guard mentionStartLocation == nil else { return }
        let selection = currentClampedSelection()
        guard selection.location != NSNotFound else { return }
        mentionStartLocation = selection.location
    }

    func endMentionSession() {
        mentionStartLocation = nil
        // Inform coordinator so any overlay still showing is closed.
        mentionDelegate?.mentionAbort()
    }

    func resetTransientEditingState() {
        clampSelectionToCurrentString()
        guard mentionStartLocation != nil else { return }
        endMentionSession()
    }

    private func queryString() -> String {
        guard let start = clampedMentionStartLocation() else { return "" }
        let selection = currentClampedSelection()
        guard selection.length == 0, selection.location > start else { return "" }
        let textLength = currentStringLength()
        let queryStart = min(start + 1, textLength)
        let range = NSRange(
            location: queryStart,
            length: max(0, selection.location - queryStart)
        ).clamped(to: textLength)
        guard NSMaxRange(range) <= textLength else { return "" }
        return (string as NSString).substring(with: range)
    }

    // MARK: – Insert token ---------------------------------------------------

    func insertMentionToken(_ suggestion: MentionSuggestion) {
        guard let replaceRange = mentionReplacementRange() else {
            resetTransientEditingState()
            return
        }
        let start = replaceRange.location
        let tokenText = "@\(suggestion.relativePath)"

        // Inherit the attributes that are active at the insertion point so we
        // don't override the dynamic (light/dark-aware) foreground colour or
        // any user-selected font styling.
        var baseAttributes: [NSAttributedString.Key: Any] = typingAttributes
        if
            let ts = textStorage,
            ts.length > 0,
            start > 0
        {
            // Use the attrs of the preceding character as a closer match when
            // we are not at the very start of the document.
            baseAttributes = ts.attributes(at: start - 1, effectiveRange: nil)
        }

        let attr = NSMutableAttributedString(
            string: tokenText,
            attributes: baseAttributes
        )

        let payload = MentionTokenPayload(
            relativePath: suggestion.relativePath,
            kind: suggestion.kind
        )
        attr.addAttribute(
            .mentionToken,
            value: payload,
            range: NSRange(location: 0, length: attr.length)
        )

        textStorage?.replaceCharacters(in: replaceRange, with: attr)

        // Move caret & add trailing space
        let insertionPoint = min(start + attr.length, currentStringLength())
        setSelectedRange(NSRange(location: insertionPoint, length: 0))
        insertText(" ", replacementRange: currentClampedSelection())

        // Inform AppKit that the text changed so delegates/bindings update
        didChangeText()

        endMentionSession()
    }

    // MARK: – Focus handling -------------------------------------------------

    override func resignFirstResponder() -> Bool {
        let didResign = super.resignFirstResponder()
        if didResign {
            endMentionSession()
        }
        return didResign
    }

    // MARK: – Window-lifecycle ----------------------------------------------

    /// Called whenever the text view is detached from or attached to a window.
    /// We use it to guarantee the suggestion overlays disappear when the view
    /// is removed (e.g. the parent window is closing).
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        // If we are being detached (`newWindow == nil`) close any active overlays.
        if newWindow == nil {
            beginTeardown()
        } else {
            isTearingDown = false
        }
        super.viewWillMove(toWindow: newWindow)
    }

    /// Called whenever the NSView is added to or removed from a super-view
    override func viewWillMove(toSuperview newSuperview: NSView?) {
        // If we are being removed from the view hierarchy, end any mention session
        if newSuperview == nil {
            beginTeardown()
        }
        super.viewWillMove(toSuperview: newSuperview)
    }

    // MARK: – Token-aware deletion ------------------------------------------

    override func deleteBackward(_ sender: Any?) {
        if !deleteTokenIfNeeded(isForwardDelete: false) {
            super.deleteBackward(sender)
        }
    }

    override func deleteForward(_ sender: Any?) {
        if !deleteTokenIfNeeded(isForwardDelete: true) {
            super.deleteForward(sender)
        }
    }

    /// Returns `true` if a mention token was found & removed.
    private func deleteTokenIfNeeded(isForwardDelete: Bool) -> Bool {
        guard
            let ts = textStorage,
            let delegate = mentionDelegate
        else { return false }

        // When there's a selection, let the normal delete behavior handle it.
        // We just need to notify about any tokens that will be removed.
        if selectedRange.length > 0 {
            notifyTokensInRange(selectedRange, delegate: delegate)
            return false // Let super handle the actual deletion
        }

        // Single-character delete: determine the character index to inspect.
        let indexToInspect: Int = isForwardDelete
            ? selectedRange.location
            : max(selectedRange.location - 1, 0)

        // Ensure index is within bounds
        guard indexToInspect < ts.length else { return false }

        var effective = NSRange(location: 0, length: 0)
        guard let payload = ts.attribute(
            .mentionToken,
            at: indexToInspect,
            effectiveRange: &effective
        ) as? MentionTokenPayload
        else { return false }

        // Remove the whole token in one shot.
        ts.replaceCharacters(in: effective, with: "")
        // Place the caret at the start of the now-deleted token.
        setSelectedRange(NSRange(location: effective.location, length: 0))

        // Notify delegate so the model can de-select.
        delegate.tokenRemoved(payload)

        // Inform AppKit that the text changed so delegates/bindings update
        didChangeText()
        return true
    }

    /// Finds all mention tokens in the given range and notifies the delegate about each.
    private func notifyTokensInRange(_ range: NSRange, delegate: MentionTextViewDelegate) {
        guard let ts = textStorage else { return }
        let clampedRange = NSIntersectionRange(range, NSRange(location: 0, length: ts.length))
        guard clampedRange.length > 0 else { return }

        ts.enumerateAttribute(.mentionToken, in: clampedRange, options: []) { value, _, _ in
            if let payload = value as? MentionTokenPayload {
                delegate.tokenRemoved(payload)
            }
        }
    }

    // MARK: – Helpers

    private func notifyCaretPosition() {
        guard !isComposingText else {
            resetTransientEditingState()
            return
        }
        let selection = clampSelectionToCurrentString()
        let caret = firstRect(
            forCharacterRange: selection,
            actualRange: nil
        )
        mentionDelegate?.mentionStarted(at: caret)
        mentionDelegate?.mentionQueryChanged("", parent: nil)
    }

    private func currentClampedSelection() -> NSRange {
        clampSelectionToCurrentString()
    }

    private func clampedMentionStartLocation() -> Int? {
        guard let start = mentionStartLocation, start != NSNotFound else { return nil }
        let textLength = currentStringLength()
        guard start >= 0, start <= textLength else { return nil }
        return start
    }

    private func mentionReplacementRange() -> NSRange? {
        guard let start = clampedMentionStartLocation() else { return nil }
        let selection = currentClampedSelection()
        guard selection.length == 0, selection.location >= start else { return nil }
        return NSRange(location: start, length: selection.location - start)
    }
}
