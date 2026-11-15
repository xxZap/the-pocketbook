//
//  NoteEditorView.swift
//  the pocketbook
//

import PhotosUI
import SwiftData
import SwiftUI

/// The full-screen cover: the opened page, plus any page reached through its links.
struct NoteEditorScreen: View {
    let note: Note
    var startsWithTitleFocus = false
    var onDelete: (Note) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var path: [Note] = []

    var body: some View {
        NavigationStack(path: $path) {
            page(for: note, focusTitle: startsWithTitleFocus)
                .navigationDestination(for: Note.self) { linked in
                    if linked.isSession {
                        ChronicleView(focus: linked, onOpenLink: { path.append($0) })
                    } else {
                        page(for: linked, focusTitle: false)
                    }
                }
        }
    }

    private func page(for note: Note, focusTitle: Bool) -> some View {
        NoteEditorView(
            note: note,
            startsWithTitleFocus: focusTitle,
            onClose: { dismiss() },
            onOpenLink: { path.append($0) },
            onDelete: { onDelete(note) }
        )
    }
}

/// A single page, always editable.
struct NoteEditorView: View {
    @Bindable var note: Note
    var startsWithTitleFocus = false
    var onClose: () -> Void
    var onOpenLink: (Note) -> Void
    var onDelete: () -> Void

    enum PageLayout: String, CaseIterable, Identifiable {
        case split, text, drawing
        var id: Self { self }
        var label: String {
            switch self {
            case .split: "Testo e disegno"
            case .text: "Solo testo"
            case .drawing: "Solo disegno"
            }
        }
        var icon: String {
            switch self {
            case .split: "rectangle.split.2x1"
            case .text: "text.alignleft"
            case .drawing: "pencil.and.scribble"
            }
        }
    }

    /// What the right half of the page shows: the drawing or the attached images.
    enum VisualMode: String {
        case drawing, gallery
    }

    @Environment(\.modelContext) private var context
    @Query private var allNotes: [Note]
    @AppStorage("editorLayout") private var layout: PageLayout = .split
    @StateObject private var canvasController = CanvasController()
    @StateObject private var linkController = LinkTextController()
    @FocusState private var titleFocused: Bool
    @State private var confirmingDelete = false
    @State private var confirmingClear = false
    /// Title that other pages currently use to link here; updated when a rename is propagated.
    @State private var linkedTitle: String?
    @State private var pickedItems: [PhotosPickerItem] = []
    @State private var visualMode: VisualMode = .drawing
    @State private var shareError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 28)
                .padding(.top, 8)
                .padding(.bottom, 14)
            Divider().overlay(Theme.margin)
            pages
        }
        .background(Theme.paper)
        .toolbar { toolbar }
        .toolbarBackground(Theme.paper, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: note.title) { note.updatedAt = .now }
        .onChange(of: note.text) { note.updatedAt = .now }
        .onChange(of: note.drawingData) { note.updatedAt = .now }
        .onChange(of: note.questionStateRaw) { note.updatedAt = .now }
        .onChange(of: pickedItems) { _, items in attach(items) }
        .onChange(of: titleFocused) { _, focused in
            if !focused { propagateRename() }
        }
        .onAppear {
            if linkedTitle == nil { linkedTitle = note.linkTitle }
            note.galleryIndex = min(note.galleryIndex, max(note.images.count - 1, 0))
            if let saved = note.visualModeRaw.flatMap(VisualMode.init(rawValue:)) {
                visualMode = saved
            } else if note.drawing == nil && !note.images.isEmpty {
                visualMode = .gallery
            }
        }
        .onDisappear { propagateRename() }
        .task {
            if startsWithTitleFocus {
                try? await Task.sleep(for: .milliseconds(450))
                titleFocused = true
            }
        }
        .confirmationDialog("Strappare questa pagina?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Elimina pagina", role: .destructive, action: onDelete)
        } message: {
            Text("La nota verrà eliminata definitivamente.")
        }
        .alert("Condivisione non riuscita", isPresented: Binding(get: { shareError != nil }, set: { if !$0 { shareError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(shareError ?? "")
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Titolo", text: $note.title, axis: .vertical)
                .font(.system(size: 34, weight: .bold, design: .serif))
                .foregroundStyle(Theme.ink)
                .focused($titleFocused)
                .lineLimit(1...3)
            TagEditor(note: note)
            connections
            HStack(spacing: 6) {
                if note.questionState != .none {
                    Label(note.questionState.label, systemImage: note.questionState.icon)
                        .foregroundStyle(note.questionState == .open ? Theme.rust : .secondary)
                    Text("·")
                }
                Text("Creata \(note.createdAt.formatted(date: .abbreviated, time: .shortened)) · modificata \(note.updatedAt.formatted(.relative(presentation: .named)))")
            }
            .font(.system(.caption, design: .serif))
            .foregroundStyle(.secondary)
        }
    }

    private var outgoingLinks: [Note] {
        var seen = Set<PersistentIdentifier>()
        return Links.find(in: note.text, notes: allNotes)
            .map(\.note)
            .filter { $0.persistentModelID != note.persistentModelID && seen.insert($0.persistentModelID).inserted }
    }

    @ViewBuilder
    private var connections: some View {
        let outgoing = outgoingLinks
        let allBacklinks = Links.backlinks(to: note, in: allNotes)
        let backlinks = allBacklinks.filter { !$0.isSession }
        if !outgoing.isEmpty || !backlinks.isEmpty {
            FlowLayout(spacing: 6) {
                ForEach(outgoing) { linked in
                    linkChip(linked, icon: "arrow.up.right")
                }
                ForEach(backlinks) { linked in
                    linkChip(linked, icon: "arrow.turn.down.left")
                }
            }
        }
        sessionMentions(allBacklinks.filter(\.isSession))
    }

    /// The sessions that cite this page, in the order they were played: where the party has been.
    @ViewBuilder
    private func sessionMentions(_ sessions: [Note]) -> some View {
        if !sessions.isEmpty {
            let numbers = Chronicle.sessionNumbers(allNotes)
            let ordered = sessions.sorted { (numbers[$0.persistentModelID] ?? 0) < (numbers[$1.persistentModelID] ?? 0) }
            FlowLayout(spacing: 6) {
                Label("Nelle sessioni", systemImage: "book.closed")
                    .font(.system(.subheadline, design: .serif))
                    .foregroundStyle(.secondary)
                ForEach(Array(ordered.enumerated()), id: \.element.persistentModelID) { offset, session in
                    let number = numbers[session.persistentModelID] ?? 0
                    Button { onOpenLink(session) } label: {
                        Text(offset == 0 ? "\(number) · prima volta" : "\(number)")
                            .font(.system(.subheadline, design: .serif, weight: offset == 0 ? .semibold : .regular))
                            .foregroundStyle(offset == 0 ? .white : Theme.leather)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(offset == 0 ? Theme.leather : Theme.leather.opacity(0.1), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Sessione \(number)\(offset == 0 ? ", prima volta" : "")")
                    .help(session.playedAt.formatted(date: .abbreviated, time: .omitted))
                }
            }
        }
    }

    private func linkChip(_ linked: Note, icon: String) -> some View {
        Button { onOpenLink(linked) } label: {
            Label(linked.displayTitle, systemImage: icon)
                .font(.system(.subheadline, design: .serif))
                .foregroundStyle(Theme.rust)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .overlay(Capsule().strokeBorder(Theme.rust.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
        }
        .buttonStyle(.plain)
        .accessibilityHint(icon == "arrow.up.right" ? "Pagina citata qui" : "Pagina che cita questa")
    }

    // MARK: Pages

    @ViewBuilder
    private var pages: some View {
        switch layout {
        case .split:
            HStack(spacing: 0) {
                textPage
                Divider().overlay(Theme.margin)
                visualPage
            }
        case .text:
            textPage
        case .drawing:
            visualPage
        }
    }

    private var textPage: some View {
        VStack(spacing: 0) {
            LinkedTextView(text: $note.text, notes: allNotes, controller: linkController, onOpenLink: onOpenLink)
                .overlay(alignment: .topLeading) {
                    if note.text.isEmpty {
                        Text("Osservazioni, connessioni, ipotesi… scrivi @ per collegare un'altra pagina")
                            .font(.system(size: 19, design: .serif))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 27)
                            .padding(.vertical, 20)
                            .allowsHitTesting(false)
                    }
                }
            if let mention = linkController.mention {
                let suggestions = mentionSuggestions(for: mention.query)
                let canCreate = canCreatePage(named: mention.query)
                if !suggestions.isEmpty || canCreate {
                    MentionBar(
                        query: mention.query,
                        suggestions: suggestions,
                        canCreate: canCreate,
                        onPick: { linkController.completeMention(with: $0.linkTitle) },
                        onCreate: { createLinkedPage(named: mention.query) }
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .animation(.snappy(duration: 0.2), value: linkController.mention)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            linkController.acceptFirstSuggestion = { [weak linkController] in
                guard let mention = linkController?.mention,
                      let first = mentionSuggestions(for: mention.query).first else { return false }
                linkController?.completeMention(with: first.linkTitle)
                return true
            }
        }
    }

    /// Drawing and images take turns on the same half; the canvas stays alive underneath to keep its undo history.
    private var visualPage: some View {
        VStack(spacing: 0) {
            visualBar
            Divider().overlay(Theme.margin)
            ZStack {
                drawingPage
                    .background(DotGridPaper())
                    .opacity(visualMode == .drawing ? 1 : 0)
                    .allowsHitTesting(visualMode == .drawing)
                if visualMode == .gallery {
                    galleryPage
                        .background(Theme.paper)
                        .transition(.opacity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.snappy(duration: 0.2), value: visualMode)
        .onChange(of: visualMode) { _, mode in
            note.visualModeRaw = mode.rawValue
            if mode == .gallery { canvasController.hideTools() }
        }
    }

    private var visualBar: some View {
        Picker("Contenuto", selection: $visualMode) {
            Text("Disegno").tag(VisualMode.drawing)
            Text(note.images.isEmpty ? "Immagini" : "Immagini · \(note.images.count)").tag(VisualMode.gallery)
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 260)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .trailing) { visualAction }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.paper)
    }

    /// The one action that belongs to the current mode.
    @ViewBuilder
    private var visualAction: some View {
        switch visualMode {
        case .drawing:
            if note.drawing != nil {
                Button("Pulisci disegno", systemImage: "eraser") { confirmingClear = true }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(Theme.rust)
                    .frame(width: 36, height: 36)
                    .confirmationDialog("Pulire il disegno?", isPresented: $confirmingClear, titleVisibility: .visible) {
                        Button("Pulisci disegno", role: .destructive) { canvasController.clear() }
                    } message: {
                        Text("Tutti i tratti di questa pagina verranno cancellati.")
                    }
            }
        case .gallery:
            PhotosPicker(selection: $pickedItems, matching: .images) {
                Label("Aggiungi immagini", systemImage: "plus")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(Theme.rust)
                    .frame(width: 36, height: 36)
            }
        }
    }

    @ViewBuilder
    private var galleryPage: some View {
        if note.images.isEmpty {
            ContentUnavailableView {
                Label("Nessuna immagine", systemImage: "photo.on.rectangle")
                    .font(.system(.title3, design: .serif))
            } description: {
                Text("Foto e scansioni allegate a questa pagina restano qui, separate dal disegno.")
                    .font(.system(.body, design: .serif))
            } actions: {
                PhotosPicker(selection: $pickedItems, matching: .images) {
                    Text("Aggiungi immagini")
                }
                .tint(Theme.rust)
            }
        } else {
            ImageGallery(images: note.sortedImages, selection: $note.galleryIndex, onDelete: removeImage)
        }
    }

    private var drawingPage: some View {
        DrawingCanvas(data: $note.drawingData, controller: canvasController)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
    }

    // MARK: Images

    private func attach(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        pickedItems = []
        Task {
            for item in items {
                guard let raw = try? await item.loadTransferable(type: Data.self),
                      let data = await Task.detached(operation: { ImageCodec.normalized(raw) }).value
                else { continue }
                let image = NoteImage(data: data)
                context.insert(image)
                image.note = note
            }
            note.updatedAt = .now
            if layout == .text { layout = .split }
            visualMode = .gallery
            note.galleryIndex = max(note.images.count - 1, 0)
        }
    }

    private func removeImage(_ image: NoteImage) {
        note.images.removeAll { $0.persistentModelID == image.persistentModelID }
        context.delete(image)
        note.updatedAt = .now
        note.galleryIndex = min(note.galleryIndex, max(note.images.count - 1, 0))
    }

    private func showDrawingTools() {
        visualMode = .drawing
        canvasController.showTools()
    }

    // MARK: Links

    private func mentionSuggestions(for query: String) -> [Note] {
        Links.suggestions(for: query, excluding: note, in: allNotes)
    }

    private func canCreatePage(named query: String) -> Bool {
        Links.canCreatePage(named: query, in: allNotes)
    }

    private func createLinkedPage(named query: String) {
        let name = query.trimmingCharacters(in: .whitespaces)
        context.insert(Note(title: name))
        linkController.completeMention(with: name)
    }

    /// Keeps `@OldTitle` links in other pages pointing here after the title changes.
    private func propagateRename() {
        let newTitle = note.linkTitle
        guard let oldTitle = linkedTitle, oldTitle != newTitle else { return }
        Links.rename(note, from: oldTitle, to: newTitle, in: allNotes)
        if !newTitle.isEmpty { linkedTitle = newTitle }
    }

    // MARK: Sharing

    /// Hands the page to the share sheet as a `.pocketbook` file another notebook can open.
    private func share() {
        propagateRename()
        do {
            ShareSheet.present(try PageSharing.write(note))
        } catch {
            shareError = error.localizedDescription
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("Chiudi", systemImage: "xmark", action: onClose)
        }
        ToolbarItem(placement: .principal) {
            Picker("Layout", selection: $layout) {
                ForEach(PageLayout.allCases) { layout in
                    Image(systemName: layout.icon)
                        .accessibilityLabel(layout.label)
                        .tag(layout)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 220)
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu {
                Picker("Domanda", selection: $note.questionState) {
                    ForEach(QuestionState.allCases) { state in
                        Label(state.label, systemImage: state.icon).tag(state)
                    }
                }
            } label: {
                Label("Domanda", systemImage: note.questionState.icon)
            }
            PhotosPicker(selection: $pickedItems, matching: .images) {
                Label("Aggiungi immagini", systemImage: "photo.badge.plus")
            }
            if layout != .text {
                Button("Strumenti di disegno", systemImage: "pencil.tip.crop.circle", action: showDrawingTools)
            }
            Button("Condividi pagina", systemImage: "square.and.arrow.up", action: share)
                .disabled(note.isBlank)
            Button("Elimina", systemImage: "trash", role: .destructive) {
                confirmingDelete = true
            }
        }
    }
}
