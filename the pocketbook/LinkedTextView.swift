//
//  LinkedTextView.swift
//  the pocketbook
//

import Combine
import SwiftUI
import UIKit

/// Shares the `@` mention being typed with SwiftUI and lets it complete the mention.
final class LinkTextController: ObservableObject {
    @Published var mention: Mention?
    weak var textView: UITextView?
    /// Set by the editor: picks the first suggestion when Return is pressed mid-mention.
    var acceptFirstSuggestion: (() -> Bool)?
    fileprivate var textDidChange: ((UITextView) -> Void)?

    /// Replaces the `@query` being typed with a complete `@Title `.
    func completeMention(with title: String) {
        guard let textView, let mention else { return }
        let replacement = "@\(title) "
        let text = (textView.text as NSString).replacingCharacters(in: mention.range, with: replacement)
        textView.text = text
        textView.selectedRange = NSRange(location: mention.range.location + (replacement as NSString).length, length: 0)
        textDidChange?(textView)
    }
}

/// Plain-text editor that highlights `@Title` links and opens them on tap.
struct LinkedTextView: UIViewRepresentable {
    @Binding var text: String
    /// Every note that can be linked, including the one being edited.
    let notes: [Note]
    let controller: LinkTextController
    let onOpenLink: (Note) -> Void
    /// False inside a scroll view: the text grows with its content instead of scrolling on its own.
    var scrolls = true

    static let font: UIFont = {
        let base = UIFont.systemFont(ofSize: 19)
        return UIFont(descriptor: base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor, size: 19)
    }()

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 20, left: 22, bottom: 20, right: 22)
        textView.textContainer.lineFragmentPadding = 5
        textView.isScrollEnabled = scrolls
        textView.alwaysBounceVertical = scrolls
        textView.keyboardDismissMode = .interactive
        textView.delegate = context.coordinator
        context.coordinator.textView = textView
        textView.accessibilityIdentifier = "noteBody"
        textView.text = text
        textView.setContentHuggingPriority(.defaultLow, for: .vertical)
        textView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.delegate = context.coordinator
        textView.addGestureRecognizer(tap)

        controller.textView = textView
        controller.textDidChange = { [weak coordinator = context.coordinator] in coordinator?.textViewDidChange($0) }
        context.coordinator.restyleAll(textView)
        return textView
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView textView: UITextView, context: Context) -> CGSize? {
        guard !scrolls, let width = proposal.width, width.isFinite else { return nil }
        let fitting = textView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: fitting.height)
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        // While the user types, the view is ahead of the binding (writes are debounced):
        // never overwrite it then. Same while the keyboard composes an accented letter
        // (dead keys, "`" then "o" → "ò"): overwriting the marked text would drop the letter.
        if !coordinator.hasPendingCommit, textView.markedTextRange == nil, textView.text != text {
            textView.text = text
            coordinator.restyleAll(textView)
        } else if coordinator.linkTitlesChanged() {
            coordinator.restyleAll(textView)
        }
    }

    /// Pending keystrokes reach the note even when the page closes before the debounce fires.
    static func dismantleUIView(_ textView: UITextView, coordinator: Coordinator) {
        coordinator.commit(textView)
    }

    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        var parent: LinkedTextView
        private var links: [NoteLink] = []
        /// The titles links were last resolved against; a rename elsewhere needs a full restyle.
        private var styledTitles: Set<String> = []
        /// What the last keystroke replaced, in the new text: only its paragraph is restyled.
        private var lastEdit: NSRange?
        /// A restyle was skipped while the keyboard composed; the next one must cover everything.
        private var needsFullRestyle = false
        private var pendingCommit: DispatchWorkItem?
        private var lastContentHeight: CGFloat = 0
        private var resignObserver: NSObjectProtocol?
        weak var textView: UITextView?

        /// Writing the model on every keystroke re-renders the whole editor and the notebook
        /// behind it; the text is handed over once typing pauses.
        private static let commitDelay: TimeInterval = 0.35

        init(_ parent: LinkedTextView) {
            self.parent = parent
            super.init()
            resignObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                guard let self, let textView = self.textView else { return }
                self.commit(textView)
            }
        }

        deinit {
            if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        }

        var hasPendingCommit: Bool { pendingCommit != nil }

        /// Hands the text to the binding now, cancelling any scheduled write.
        func commit(_ textView: UITextView) {
            pendingCommit?.cancel()
            pendingCommit = nil
            let current = textView.text ?? ""
            if parent.text != current { parent.text = current }
        }

        private func scheduleCommit(_ textView: UITextView) {
            pendingCommit?.cancel()
            let work = DispatchWorkItem { [weak self, textView] in self?.commit(textView) }
            pendingCommit = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.commitDelay, execute: work)
        }

        private static let baseAttributes: [NSAttributedString.Key: Any] = {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 4
            return [.font: LinkedTextView.font, .foregroundColor: UIColor(Theme.ink), .paragraphStyle: paragraph]
        }()

        private static let linkAttributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: UIColor(Theme.rust),
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .underlineColor: UIColor(Theme.rust).withAlphaComponent(0.4),
        ]

        private var currentTitles: Set<String> {
            Set(parent.notes.lazy.filter { !$0.isSession }.map(\.linkTitle))
        }

        func linkTitlesChanged() -> Bool {
            currentTitles != styledTitles
        }

        func restyleAll(_ textView: UITextView) {
            restyle(textView, around: nil)
        }

        /// Colours `@Title` links. With an `edit`, only the paragraphs it touches are re-attributed:
        /// resetting the whole storage would re-lay out the entire note on every keystroke.
        private func restyle(_ textView: UITextView, around edit: NSRange?) {
            // Touching attributes while the keyboard composes (marked text) breaks the composition.
            guard textView.markedTextRange == nil else {
                needsFullRestyle = true
                return
            }
            let storage = textView.textStorage
            let ns = storage.string as NSString
            styledTitles = currentTitles
            links = Links.find(in: storage.string, notes: parent.notes)

            var range = NSRange(location: 0, length: storage.length)
            if let edit, !needsFullRestyle, NSMaxRange(edit) <= ns.length {
                range = ns.paragraphRange(for: edit)
                for link in links where NSIntersectionRange(link.range, range).length > 0 {
                    range = NSUnionRange(range, link.range)
                }
            }
            needsFullRestyle = false

            let selection = textView.selectedRange
            storage.beginEditing()
            storage.setAttributes(Self.baseAttributes, range: range)
            for link in links {
                let overlap = NSIntersectionRange(link.range, range)
                if overlap.length > 0 { storage.addAttributes(Self.linkAttributes, range: overlap) }
            }
            storage.endEditing()
            if textView.selectedRange != selection { textView.selectedRange = selection }
            textView.typingAttributes = Self.baseAttributes
        }

        private func updateMention(_ textView: UITextView) {
            let selection = textView.selectedRange
            let mention = selection.length == 0
                ? Links.activeMention(in: textView.text, caret: selection.location, notes: parent.notes)
                : nil
            let controller = parent.controller
            guard controller.mention != mention else { return }
            // Delegate callbacks can fire during a SwiftUI update; publish afterwards.
            DispatchQueue.main.async { controller.mention = mention }
        }

        func textViewDidChange(_ textView: UITextView) {
            restyle(textView, around: lastEdit)
            lastEdit = nil
            updateMention(textView)

            let height = textView.contentSize.height
            let heightChanged = height != lastContentHeight
            lastContentHeight = height
            if parent.text.isEmpty != textView.text.isEmpty || (!parent.scrolls && heightChanged) {
                // The placeholder and a growing (non-scrolling) text view need SwiftUI right away.
                commit(textView)
            } else {
                scheduleCommit(textView)
            }
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            updateMention(textView)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            commit(textView)
            DispatchQueue.main.async { [controller = parent.controller] in controller.mention = nil }
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            if text == "\n", parent.controller.mention != nil, parent.controller.acceptFirstSuggestion?() == true {
                return false
            }
            lastEdit = NSRange(location: range.location, length: (text as NSString).length)
            return true
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let textView = gesture.view as? UITextView,
                  let characterRange = textView.characterRange(at: gesture.location(in: textView))
            else { return }
            let index = textView.offset(from: textView.beginningOfDocument, to: characterRange.start)
            if let link = links.first(where: { NSLocationInRange(index, $0.range) }) {
                parent.onOpenLink(link.note)
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}

/// Suggestions shown while typing `@…`.
struct MentionBar: View {
    let query: String
    let suggestions: [Note]
    let canCreate: Bool
    let onPick: (Note) -> Void
    let onCreate: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "at")
                .foregroundStyle(Theme.rust)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(suggestions) { note in
                        Button { onPick(note) } label: {
                            Label(note.displayTitle, systemImage: "doc.text")
                                .lineLimit(1)
                        }
                        .buttonStyle(.bordered)
                    }
                    if canCreate {
                        let create = Button(action: onCreate) {
                            Label("Nuova pagina «\(query.trimmingCharacters(in: .whitespaces))»", systemImage: "plus")
                                .lineLimit(1)
                        }
                        // Stand out only when no existing page matches.
                        if suggestions.isEmpty {
                            create.buttonStyle(.borderedProminent)
                        } else {
                            create.buttonStyle(.bordered)
                        }
                    }
                }
                .font(.system(.subheadline, design: .serif))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.paper)
        .overlay(alignment: .top) { Divider() }
    }
}
