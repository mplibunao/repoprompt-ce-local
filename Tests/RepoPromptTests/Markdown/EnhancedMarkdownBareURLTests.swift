import AppKit
import Markdown
@testable import RepoPromptApp
import SwiftUI
import XCTest

final class EnhancedMarkdownBareURLTests: XCTestCase {
    func testBareProseURLLinksOnlyWhenPolicyEnabled() {
        let disabled = compile("Visit https://example.com", policy: .disabled)
        XCTAssertTrue(linkedSubstrings(in: disabled).isEmpty)

        let enabled = compile("Visit https://example.com", policy: .httpHTTPSOnly)
        XCTAssertEqual(linkedSubstrings(in: enabled), ["https://example.com"])
    }

    func testExplicitMarkdownLinkStillWorksWhenBareURLPolicyDisabled() throws {
        let attributed = compile("Visit [the docs](https://example.com/docs)", policy: .disabled)

        XCTAssertEqual(linkedSubstrings(in: attributed), ["the docs"])
        let rawRange = try XCTUnwrap(linkRanges(in: attributed).first)
        XCTAssertEqual(
            attributed.attribute(.markdownRawLink, at: rawRange.location, effectiveRange: nil) as? String,
            "https://example.com/docs"
        )
    }

    func testInlineCodeURLDoesNotBecomeBareLink() {
        let attributed = compile("Inline `https://code.example` then https://prose.example", policy: .httpHTTPSOnly)

        XCTAssertEqual(linkedSubstrings(in: attributed), ["https://prose.example"])
    }

    func testFencedCodeBlockURLDoesNotBecomeBareLink() {
        let markdown = """
        ```
        curl https://code.example
        ```

        Prose https://prose.example
        """
        let attributed = compile(markdown, policy: .httpHTTPSOnly)

        XCTAssertEqual(linkedSubstrings(in: attributed), ["https://prose.example"])
    }

    func testPreviewLikeMarkdownProtectsInlineAndFencedCodeURLs() {
        let markdown = """
        Inline `https://inline-code.example` stays code.

        ```bash
        curl https://fenced-code.example
        ```

        Prose https://prose.example.
        """
        let attributed = compile(markdown, policy: .httpHTTPSOnly, suppressBareLinksTouchingEndBoundary: true)

        XCTAssertEqual(linkedSubstrings(in: attributed), ["https://prose.example"])
    }

    func testPreviewBoundarySuppressionRemovesBareURLAtDocumentEnd() {
        let completeBeforeBoundary = compile(
            "Prose https://example.com.",
            policy: .httpHTTPSOnly,
            suppressBareLinksTouchingEndBoundary: true
        )
        XCTAssertEqual(linkedSubstrings(in: completeBeforeBoundary), ["https://example.com"])

        let touchingBoundary = compile(
            "Prose https://example.com",
            policy: .httpHTTPSOnly,
            suppressBareLinksTouchingEndBoundary: true
        )
        XCTAssertTrue(linkedSubstrings(in: touchingBoundary).isEmpty)

        assertSuppressedBareURLIsNotVisuallyMarked(touchingBoundary, urlText: "https://example.com")
    }

    func testExplicitMarkdownLinkAtDocumentEndSurvivesBoundarySuppression() throws {
        let attributed = compile(
            "Visit [the docs](https://example.com/docs)",
            policy: .httpHTTPSOnly,
            suppressBareLinksTouchingEndBoundary: true
        )
        let linkRange = try XCTUnwrap(linkRanges(in: attributed).first)

        XCTAssertEqual(linkedSubstrings(in: attributed), ["the docs"])
        XCTAssertEqual(
            attributed.attribute(.markdownRawLink, at: linkRange.location, effectiveRange: nil) as? String,
            "https://example.com/docs"
        )
        XCTAssertNil(attributed.attribute(.repoPromptBareURLLink, at: linkRange.location, effectiveRange: nil))
    }

    func testExplicitMarkdownLinkWithURLLabelSurvivesBoundarySuppression() throws {
        let attributed = compile(
            "[https://example.com](https://example.com/docs)",
            policy: .httpHTTPSOnly,
            suppressBareLinksTouchingEndBoundary: true
        )
        let linkRange = try XCTUnwrap(linkRanges(in: attributed).first)

        XCTAssertEqual(linkedSubstrings(in: attributed), ["https://example.com"])
        XCTAssertEqual(
            attributed.attribute(.markdownRawLink, at: linkRange.location, effectiveRange: nil) as? String,
            "https://example.com/docs"
        )
        XCTAssertNil(attributed.attribute(.repoPromptBareURLLink, at: linkRange.location, effectiveRange: nil))
    }

    func testImageGeneratedLinkAtDocumentEndSurvivesBoundarySuppression() throws {
        let attributed = compile(
            "![Diagram](https://example.com/image.png)",
            policy: .httpHTTPSOnly,
            suppressBareLinksTouchingEndBoundary: true
        )
        let linkRange = try XCTUnwrap(linkRanges(in: attributed).first)

        XCTAssertEqual(linkedSubstrings(in: attributed), ["Diagram (example.com)"])
        XCTAssertNil(attributed.attribute(.repoPromptBareURLLink, at: linkRange.location, effectiveRange: nil))
    }

    func testSymbolGeneratedLinkDoesNotReceiveBareURLMarker() throws {
        let attributed = compile(
            "``https://example.com/symbol``",
            policy: .httpHTTPSOnly,
            suppressBareLinksTouchingEndBoundary: true,
            options: .parseSymbolLinks
        )
        let linkRange = try XCTUnwrap(linkRanges(in: attributed).first)

        XCTAssertEqual(linkedSubstrings(in: attributed), ["https://example.com/symbol"])
        XCTAssertNil(attributed.attribute(.repoPromptBareURLLink, at: linkRange.location, effectiveRange: nil))
    }

    @MainActor
    func testMarkdownWebLinkClickFallsThroughToAppKitDefaultOpening() throws {
        let attributed = compile("Visit https://example.com", policy: .httpHTTPSOnly)
        let linkRange = try XCTUnwrap(linkRanges(in: attributed).first)
        let textView = NSTextView()
        textView.textStorage?.setAttributedString(attributed)
        let coordinator = MarkdownTextViewCoordinator()

        XCTAssertFalse(try coordinator.textView(textView, clickedOnLink: XCTUnwrap(URL(string: "https://example.com")), at: linkRange.location))
    }

    func testRenderSignatureConfigurationIncludesBareURLPolicy() {
        let disabled = MarkdownRenderSignature(
            text: "https://example.com",
            fontSize: 13,
            forceTextColor: nil,
            useMonospaced: false,
            bareURLLinkificationPolicy: .disabled
        )
        let enabled = MarkdownRenderSignature(
            text: "https://example.com",
            fontSize: 13,
            forceTextColor: nil,
            useMonospaced: false,
            bareURLLinkificationPolicy: .httpHTTPSOnly
        )

        XCTAssertNotEqual(disabled, enabled)
        XCTAssertFalse(disabled.hasSameRenderingConfiguration(as: enabled))
        XCTAssertNil(MarkdownStreamingAppendDelta.between(previous: disabled, requested: enabled))
    }

    func testRenderSignatureConfigurationIncludesBoundarySuppression() {
        let ordinary = MarkdownRenderSignature(
            text: "https://example.com",
            fontSize: 13,
            forceTextColor: nil,
            useMonospaced: false,
            bareURLLinkificationPolicy: .httpHTTPSOnly
        )
        let preview = MarkdownRenderSignature(
            text: "https://example.com",
            fontSize: 13,
            forceTextColor: nil,
            useMonospaced: false,
            bareURLLinkificationPolicy: .httpHTTPSOnly,
            suppressBareLinksTouchingEndBoundary: true
        )

        XCTAssertNotEqual(ordinary, preview)
        XCTAssertFalse(ordinary.hasSameRenderingConfiguration(as: preview))
        XCTAssertNil(MarkdownStreamingAppendDelta.between(previous: ordinary, requested: preview))
    }

    private func assertSuppressedBareURLIsNotVisuallyMarked(
        _ attributed: NSAttributedString,
        urlText: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let range = (attributed.string as NSString).range(of: urlText)
        XCTAssertNotEqual(range.location, NSNotFound, file: file, line: line)
        guard range.location != NSNotFound else { return }

        XCTAssertNil(attributed.attribute(.link, at: range.location, effectiveRange: nil), file: file, line: line)
        XCTAssertNil(attributed.attribute(.repoPromptBareURLLink, at: range.location, effectiveRange: nil), file: file, line: line)
        XCTAssertNil(attributed.attribute(.underlineStyle, at: range.location, effectiveRange: nil), file: file, line: line)
        let foregroundColor = attributed.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
        XCTAssertFalse(foregroundColor?.isEqual(NSColor.linkColor) ?? false, file: file, line: line)
    }

    private func compile(
        _ markdown: String,
        policy: BareURLLinkificationPolicy,
        suppressBareLinksTouchingEndBoundary: Bool = false,
        options: ParseOptions = []
    ) -> NSAttributedString {
        var compiler = EnhancedMarkdownCompiler()
        compiler.fontSize = 13
        compiler.bareURLLinkificationPolicy = policy
        compiler.suppressBareLinksTouchingEndBoundary = suppressBareLinksTouchingEndBoundary
        return compiler.attributedString(from: Document(parsing: markdown, options: options))
    }
}

@MainActor
final class MarkdownPresentationUpdateTests: XCTestCase {
    func testHiddenUpdatesKeepSelectionAndRevealOnlyLatestLargeMarkdown() {
        let source = String(
            repeating: "## Section\n\nA **bold** paragraph with a [link](https://example.com).\n\n```swift\nlet value = 42\n```\n\n",
            count: 1200
        )
        let initial = Self.compile(source)
        let textView = CodeBlockTextView()
        let coordinator = MarkdownTextViewCoordinator()
        func render(_ text: NSAttributedString, visible: Bool) {
            AttributedTextView(attributedString: text, isEditable: false, allowsTextSelection: true)
                .updateTextView(textView, coordinator: coordinator, presentationVisible: visible)
        }
        render(initial, visible: true)
        let selection = NSRange(location: 100, length: 500)
        textView.setSelectedRange(selection)
        let installed = NSAttributedString(attributedString: textView.attributedString())
        let initialVersion = textView.contentVersion

        for index in 0 ..< 20 {
            render(NSAttributedString(string: source + "Intermediate \(index)"), visible: false)
        }
        XCTAssertTrue(textView.attributedString().isEqual(to: installed))
        XCTAssertEqual(textView.selectedRange(), selection)
        XCTAssertEqual(textView.contentVersion, initialVersion)

        let latest = NSMutableAttributedString(attributedString: initial)
        latest.append(NSAttributedString(string: "Latest state"))
        render(latest, visible: true)
        XCTAssertEqual(textView.string, latest.string)
        XCTAssertEqual(textView.contentVersion, initialVersion + 1)
        XCTAssertEqual(textView.selectedRange(), selection)

        // The caller's own value again, not a copy of the installed storage, which AppKit has
        // already normalized.
        render(latest, visible: true)
        XCTAssertEqual(textView.contentVersion, initialVersion + 1, "Unchanged content must not replace text storage again")
    }

    func testHiddenEditableContentStillUpdates() {
        let textView = CodeBlockTextView()
        let coordinator = MarkdownTextViewCoordinator()
        let text = NSAttributedString(string: "Latest editable draft")
        AttributedTextView(attributedString: text, isEditable: true, allowsTextSelection: true)
            .updateTextView(textView, coordinator: coordinator, presentationVisible: false)
        XCTAssertEqual(textView.string, text.string)
        XCTAssertTrue(textView.isEditable)
        XCTAssertEqual(textView.contentVersion, 1)
    }

    func testInteractionFlagsAreRepairedAndDelegateRefreshDoesNotReplaceEqualContent() {
        let textView = CodeBlockTextView()
        let requested = Self.compile("""
        Prose with **bold**, `code`, and a [link](https://example.com).

        ```swift
        let value = 42
        let other = 7
        ```

        | Marker | Value |
        | --- | --- |
        | A | 1 |
        | B | 2 |

        - item one
        - item two
        """)
        let first = MarkdownTextViewCoordinator()
        AttributedTextView(attributedString: requested, isEditable: false, allowsTextSelection: true)
            .updateTextView(textView, coordinator: first, presentationVisible: true)
        let version = textView.contentVersion
        textView.isEditable = true
        textView.isSelectable = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.isGrammarCheckingEnabled = true
        textView.isAutomaticSpellingCorrectionEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = true
        textView.isAutomaticTextReplacementEnabled = true

        let next = MarkdownTextViewCoordinator()
        AttributedTextView(attributedString: requested, isEditable: false, allowsTextSelection: true)
            .updateTextView(textView, coordinator: next, presentationVisible: true)
        XCTAssertFalse(textView.isEditable)
        XCTAssertTrue(textView.isSelectable)
        XCTAssertFalse(textView.isContinuousSpellCheckingEnabled)
        XCTAssertFalse(textView.isGrammarCheckingEnabled)
        XCTAssertFalse(textView.isAutomaticSpellingCorrectionEnabled)
        XCTAssertFalse(textView.isAutomaticQuoteSubstitutionEnabled)
        XCTAssertFalse(textView.isAutomaticTextReplacementEnabled)
        XCTAssertTrue(textView.delegate === next)
        XCTAssertEqual(textView.contentVersion, version, "Equal compiled content must not replace text storage")

        let restyled = NSMutableAttributedString(attributedString: requested)
        restyled.addAttribute(.foregroundColor, value: NSColor.systemRed, range: NSRange(location: 0, length: 5))
        for _ in 0 ..< 2 {
            AttributedTextView(attributedString: restyled, isEditable: false, allowsTextSelection: true)
                .updateTextView(textView, coordinator: next, presentationVisible: true)
        }
        XCTAssertEqual(
            textView.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
            NSColor.systemRed
        )
        XCTAssertEqual(textView.contentVersion, version + 1, "An attribute-only change replaces text storage once")
    }

    #if DEBUG
        func testHiddenCompileCancellationRevealsOnlyLatestSignature() async throws {
            var compiles = 0
            AgentTranscriptTailRenderProbe.sink = { event in
                if case .markdownCompile = event {
                    compiles += 1
                }
            }
            defer { AgentTranscriptTailRenderProbe.sink = nil }

            // Single renderer. The message is long enough that a small streamed append waits for
            // the coalescing quiet window, and short enough to stay out of segmented rendering.
            let base = Self.paragraphs(110)
            let pending = base + " pending"
            let latest = pending + ", then more, then the latest"
            XCTAssertEqual(MarkdownStreamingCompileTier(text: pending), .large)
            XCTAssertFalse(MarkdownStreamingFreezeBoundaryResolver.shouldConsiderSegmentation(for: latest))

            let single = MarkdownVisibilityHost(text: base)
            defer { single.close() }
            let firstOutput = Self.compile(base).string
            try await waitUntil(single, "first compile") { single.nativeStrings == [firstOutput] }
            XCTAssertEqual(compiles, 1)

            single.model.text = pending
            single.layout()
            single.model.isPresentationVisible = false
            single.layout()
            try await idle(single)
            XCTAssertEqual(compiles, 1, "Hiding cancels the compile the append scheduled")

            single.model.text = pending + ", then more"
            single.layout()
            single.model.useMonospaced = true
            single.layout()
            single.model.text = latest
            single.layout()
            try await idle(single)
            XCTAssertEqual(compiles, 1, "Nothing compiles while hidden")
            XCTAssertEqual(single.nativeStrings, [firstOutput], "The last compiled output stays installed")

            single.model.isPresentationVisible = true
            let latestOutput = Self.compile(latest, useMonospaced: true).string
            try await waitUntil(single, "reveal") {
                single.nativeStrings == [latestOutput] && single.firstFontIsFixedPitch
            }
            XCTAssertEqual(compiles, 2, "Reveal compiles only the latest request")
            try await idle(single)
            XCTAssertEqual(compiles, 2)
            XCTAssertEqual(single.nativeStrings, [latestOutput], "No earlier request lands after reveal")

            // Segmented rendering. The prefix and tail children each defer while hidden.
            let longBase = Self.paragraphs(300)
            let boundary = try XCTUnwrap(MarkdownStreamingFreezeBoundaryResolver.resolveBoundary(in: longBase))
            func expectedOutputs(_ text: String) throws -> [String] {
                let parts = try XCTUnwrap(
                    MarkdownStreamingFreezeBoundaryResolver.split(text: text, atUTF16Offset: boundary.utf16Offset)
                )
                return [Self.compile(parts.prefix).string, Self.compile(parts.tail).string].sorted()
            }
            let segmented = MarkdownVisibilityHost(text: longBase)
            defer { segmented.close() }
            let mountedOutputs = try expectedOutputs(longBase)
            try await waitUntil(segmented, "segmented first compile") { segmented.nativeStrings == mountedOutputs }

            segmented.model.isPresentationVisible = false
            segmented.layout()
            let compilesWhenHidden = compiles
            var segmentedLatest = longBase
            for index in 0 ..< 3 {
                segmentedLatest += "\n\nHidden paragraph \(index)."
                segmented.model.text = segmentedLatest
                segmented.layout()
            }
            try await idle(segmented)
            XCTAssertEqual(compiles, compilesWhenHidden, "No segmented child compiles while hidden")
            XCTAssertEqual(segmented.nativeStrings, mountedOutputs)

            segmented.model.isPresentationVisible = true
            let revealedOutputs = try expectedOutputs(segmentedLatest)
            try await waitUntil(segmented, "segmented reveal") { segmented.nativeStrings == revealedOutputs }
        }

        /// Lays out the host and services the main actor until `condition` holds.
        private func waitUntil(
            _ host: MarkdownVisibilityHost,
            _ label: String,
            until condition: () -> Bool
        ) async throws {
            let deadline = ContinuousClock.now + .seconds(5)
            while ContinuousClock.now < deadline {
                host.layout()
                if condition() {
                    return
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw MarkdownVisibilityWaitTimeout(label: label)
        }

        /// Lays out the host and services the main actor for longer than the slowest coalescing
        /// delay (0.5 seconds), so a compile that was wrongly left scheduled has run by the time
        /// the caller asserts that none did.
        private func idle(_ host: MarkdownVisibilityHost) async throws {
            let end = ContinuousClock.now + .milliseconds(700)
            while ContinuousClock.now < end {
                host.layout()
                try await Task.sleep(for: .milliseconds(20))
            }
        }

        private static func paragraphs(_ count: Int) -> String {
            (0 ..< count)
                .map { "Paragraph \($0) has **bold** text and `inline code`, padding the message to length." }
                .joined(separator: "\n\n")
        }
    #endif

    private static func compile(_ markdown: String, useMonospaced: Bool = false) -> NSAttributedString {
        var compiler = EnhancedMarkdownCompiler()
        compiler.useMonospaced = useMonospaced
        return compiler.attributedString(from: Document(parsing: markdown))
    }
}

#if DEBUG
    private struct MarkdownVisibilityWaitTimeout: Error, CustomStringConvertible {
        let label: String
        var description: String {
            "Timed out waiting for \(label)"
        }
    }

    @MainActor
    private final class MarkdownVisibilityHostModel: ObservableObject {
        @Published var text: String
        @Published var useMonospaced = false
        @Published var isPresentationVisible = true

        init(text: String) {
            self.text = text
        }
    }

    private struct MarkdownVisibilityHostView: View {
        @ObservedObject var model: MarkdownVisibilityHostModel

        var body: some View {
            MarkdownTextView(text: model.text, useMonospaced: model.useMonospaced, renderCadence: .streamingCoalesced)
                .environment(\.windowIsPresentationVisible, model.isPresentationVisible)
                .frame(width: 640, alignment: .topLeading)
        }
    }

    /// A `MarkdownTextView` in a window that is never ordered on screen. The test drives
    /// presentation visibility through the environment value directly.
    @MainActor
    private struct MarkdownVisibilityHost {
        let model: MarkdownVisibilityHostModel
        let window: NSWindow
        let hostingView: NSHostingView<MarkdownVisibilityHostView>

        init(text: String) {
            model = MarkdownVisibilityHostModel(text: text)
            hostingView = NSHostingView(rootView: MarkdownVisibilityHostView(model: model))
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 700, height: 800),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = hostingView
            hostingView.layoutSubtreeIfNeeded()
        }

        var nativeStrings: [String] {
            Self.nativeTextViews(in: hostingView).map(\.string).sorted()
        }

        var firstFontIsFixedPitch: Bool {
            guard let storage = Self.nativeTextViews(in: hostingView).first?.textStorage, storage.length > 0 else {
                return false
            }
            return (storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.isFixedPitch == true
        }

        func layout() {
            hostingView.layoutSubtreeIfNeeded()
        }

        func close() {
            window.contentView = nil
            window.close()
        }

        private static func nativeTextViews(in view: NSView) -> [CodeBlockTextView] {
            if let textView = view as? CodeBlockTextView {
                return [textView]
            }
            return view.subviews.flatMap { nativeTextViews(in: $0) }
        }
    }
#endif
