//
//  ContentView.swift
//  the pocketbook
//
//  Created by Alessio Boerio on 27/09/2026.
//

import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Note.updatedAt, order: .reverse) private var notes: [Note]
    @Query(sort: \Tag.name) private var tags: [Tag]

    @State private var searchText = ""
    @State private var tagFilter: Set<PersistentIdentifier> = []
    @State private var onlyOpenQuestions = false
    @State private var openNote: Note?
    @State private var showingChronicle = false
    @State private var newNoteID: PersistentIdentifier?
    @State private var noteToDelete: Note?
    @State private var lastRandomID: PersistentIdentifier?
    @State private var exportError: String?
    @State private var choosingFile = false
    @State private var pendingImport: PendingImport?
    @State private var importError: String?
    /// The page to open once the import sheet has closed.
    @State private var importedNote: Note?
    @Namespace private var zoom

    /// The notebook's pages; sessions live in the chronicle instead.
    private var pages: [Note] {
        notes.filter { !$0.isSession }
    }

    private var sessions: [Note] {
        notes.filter(\.isSession)
    }

    private var filteredNotes: [Note] {
        pages.filter { note in
            (!onlyOpenQuestions || note.questionState == .open)
                && tagFilter.allSatisfy { id in note.tags.contains { $0.persistentModelID == id } }
                && note.matches(searchText)
        }
    }

    private var openQuestionCount: Int {
        pages.count { $0.questionState == .open }
    }

    /// Pages are numbered in creation order, like a real notebook.
    private var pageNumbers: [PersistentIdentifier: Int] {
        let ordered = pages.sorted { $0.createdAt < $1.createdAt }
        return Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($1.persistentModelID, $0 + 1) })
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { scroller in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if !tags.isEmpty || openQuestionCount > 0 { tagFilterBar }
                        grid
                    }
                    .padding(.horizontal, 22)
                    .padding(.bottom, 40)
                }
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button("Importa", systemImage: "square.and.arrow.down") { choosingFile = true }
                        exportMenu
                        Button("Pagina a caso", systemImage: "dice") { openRandomPage(scroller) }
                            .disabled(filteredNotes.isEmpty)
                            .keyboardShortcut("r", modifiers: .command)
                    }
                }
            }
            .background(Theme.desk.ignoresSafeArea())
            .navigationTitle("Il taccuino di Giallo")
            .searchable(text: $searchText, prompt: "Cerca in titoli, testo e #tag")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Nuova pagina", systemImage: "square.and.pencil", action: createNote)
                        .keyboardShortcut("n", modifiers: .command)
                }
            }
            .overlay { emptyState }
        }
        .alert("Esportazione non riuscita", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportError ?? "")
        }
        .alert("Importazione non riuscita", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.pocketbookPage, .pdf], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { importFiles(urls) }
        }
        .onOpenURL { importFiles([$0]) }
        .sheet(item: $pendingImport, onDismiss: openImported) { pending in
            ImportSheet(pages: pending.pages) { imported in
                importedNote = imported.count == 1 ? imported.first { !$0.isSession } : nil
            }
        }
        .fullScreenCover(item: $openNote, onDismiss: tidyUp) { note in
            NoteEditorScreen(
                note: note,
                startsWithTitleFocus: note.persistentModelID == newNoteID,
                onDelete: { page in
                    noteToDelete = page
                    openNote = nil
                }
            )
            .navigationTransition(.zoom(sourceID: note.persistentModelID, in: zoom))
        }
        .fullScreenCover(isPresented: $showingChronicle, onDismiss: tidyUp) {
            ChronicleScreen(onDelete: { page in
                noteToDelete = page
                showingChronicle = false
            })
            .navigationTransition(.zoom(sourceID: Self.chronicleID, in: zoom))
        }
        .confirmationDialog("Strappare questa pagina?", isPresented: deleteDialogBinding, titleVisibility: .visible,
                            presenting: noteToDelete) { note in
            Button("Elimina \"\(note.displayTitle)\"", role: .destructive) { delete(note) }
        }
    }

    private var tagFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal.decrease")
                    .foregroundStyle(.secondary)
                if openQuestionCount > 0 || onlyOpenQuestions {
                    Button { onlyOpenQuestions.toggle() } label: {
                        Label("Domande aperte · \(openQuestionCount)", systemImage: "questionmark.circle.fill")
                            .font(.system(.subheadline, design: .serif))
                            .foregroundStyle(onlyOpenQuestions ? .white : Theme.rust)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(onlyOpenQuestions ? Theme.rust : Theme.rust.opacity(0.12), in: Capsule())
                            .overlay(Capsule().strokeBorder(Theme.rust.opacity(0.7), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                ForEach(tags) { tag in
                    let selected = tagFilter.contains(tag.persistentModelID)
                    Button {
                        if selected { tagFilter.remove(tag.persistentModelID) } else { tagFilter.insert(tag.persistentModelID) }
                    } label: {
                        TagChip(tag: tag, isSelected: selected)
                    }
                    .buttonStyle(.plain)
                }
                if !tagFilter.isEmpty || onlyOpenQuestions {
                    Button("Azzera") {
                        tagFilter.removeAll()
                        onlyOpenQuestions = false
                    }
                        .font(.system(.subheadline, design: .serif))
                }
            }
            .padding(.vertical, 4)
        }
    }

    /// The chronicle leads the grid, except while filtering by tag or question, or when a search finds nothing in it.
    private var showsChronicle: Bool {
        guard !notes.isEmpty, tagFilter.isEmpty, !onlyOpenQuestions else { return false }
        return searchText.isEmpty || sessions.contains { $0.matches(searchText) }
    }

    private var grid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 210, maximum: 290), spacing: 26)], spacing: 30) {
            if showsChronicle {
                Button { showingChronicle = true } label: {
                    ChronicleCard(sessions: sessions)
                }
                .buttonStyle(.plain)
                .matchedTransitionSource(id: Self.chronicleID, in: zoom)
            }
            ForEach(filteredNotes) { note in
                Button { openNote = note } label: {
                    NoteCard(note: note, pageNumber: pageNumbers[note.persistentModelID] ?? 0)
                }
                .buttonStyle(.plain)
                .matchedTransitionSource(id: note.persistentModelID, in: zoom)
                .id(note.persistentModelID)
                .contextMenu {
                    Button("Condividi pagina", systemImage: "square.and.arrow.up") { share(note) }
                    Button("Elimina", systemImage: "trash", role: .destructive) { noteToDelete = note }
                }
            }
        }
    }

    private static let chronicleID = "chronicle"

    @ViewBuilder
    private var emptyState: some View {
        if notes.isEmpty {
            ContentUnavailableView {
                Label("Il taccuino è vuoto", systemImage: "book.closed")
            } description: {
                Text("Capire non significa giustificare, ma inquadrare. Inizia a prendere appunti.")
            } actions: {
                Button("Nuova pagina", action: createNote)
                    .buttonStyle(.borderedProminent)
                Button("Apri la cronaca delle sessioni") { showingChronicle = true }
            }
        } else if filteredNotes.isEmpty && !showsChronicle {
            ContentUnavailableView.search(text: searchText)
        }
    }

    private var exportMenu: some View {
        Menu {
            Section("PDF, da leggere o stampare") {
                Button("Esporta tutto il taccuino", systemImage: "book") { export(pages, withChronicle: true) }
                if filteredNotes.count != pages.count {
                    Button("Esporta le pagine filtrate (\(filteredNotes.count))", systemImage: "line.3.horizontal.decrease") {
                        export(filteredNotes)
                    }
                }
            }
            Section("Per un altro iPad con il taccuino") {
                Button("Condividi tutto il taccuino", systemImage: "book.pages", action: shareNotebook)
            }
        } label: {
            Label("Esporta", systemImage: "square.and.arrow.up")
        }
        .disabled(pages.isEmpty && sessions.isEmpty)
    }

    /// Opens a random page among the visible ones, never the same twice in a row,
    /// favouring pages that have not been touched for a while.
    private func openRandomPage(_ scroller: ScrollViewProxy) {
        let candidates = filteredNotes.count > 1
            ? filteredNotes.filter { $0.persistentModelID != lastRandomID }
            : filteredNotes
        let now = Date.now
        // Weight grows with days since the last edit: forgotten pages come up more often.
        let weights = candidates.map { 1 + now.timeIntervalSince($0.updatedAt) / 86_400 }
        var pick = Double.random(in: 0..<weights.reduce(0, +))
        guard let note = zip(candidates, weights).first(where: { pick -= $1; return pick < 0 })?.0 ?? candidates.last
        else { return }

        lastRandomID = note.persistentModelID
        withAnimation { scroller.scrollTo(note.persistentModelID, anchor: .center) }
        Task {
            // Let the grid settle so the page zooms out of its own card.
            try? await Task.sleep(for: .milliseconds(350))
            openNote = note
        }
    }

    private func export(_ selection: [Note], withChronicle: Bool = false) {
        let ordered = selection.sorted { $0.createdAt < $1.createdAt }
        let numbers = Chronicle.sessionNumbers(notes)
        let chronicle = withChronicle
            ? sessions.filter { !$0.isBlank }.sorted { (numbers[$0.persistentModelID] ?? 0) < (numbers[$1.persistentModelID] ?? 0) }
            : []
        do {
            let url = try PDFExporter(notes: ordered, allNotes: notes, pageNumbers: pageNumbers, sessions: chronicle).write()
            ShareSheet.present(url)
        } catch {
            exportError = error.localizedDescription
        }
    }

    /// Every page and session, with dates and links, as a `.pocketbook` file another notebook can import whole.
    private func shareNotebook() {
        let numbers = Chronicle.sessionNumbers(notes)
        let ordered = pages.filter { !$0.isBlank }.sorted { $0.createdAt < $1.createdAt }
            + sessions.filter { !$0.isBlank }.sorted { (numbers[$0.persistentModelID] ?? 0) < (numbers[$1.persistentModelID] ?? 0) }
        do {
            ShareSheet.present(try PageSharing.write(ordered, named: "Il taccuino di Giallo"))
        } catch {
            exportError = error.localizedDescription
        }
    }

    private func share(_ note: Note) {
        do {
            ShareSheet.present(try PageSharing.write(note))
        } catch {
            exportError = error.localizedDescription
        }
    }

    /// Reads `.pocketbook` files and PDFs, then asks for confirmation before adding their pages.
    private func importFiles(_ urls: [URL]) {
        Task {
            do {
                let pages = try await Task.detached { try urls.flatMap { try PageLoader.load($0) } }.value
                guard !pages.isEmpty else { return }
                if openNote != nil {
                    // A file can arrive while a page is open: close it, the sheet needs the notebook.
                    openNote = nil
                    try? await Task.sleep(for: .milliseconds(600))
                }
                pendingImport = PendingImport(pages: pages)
            } catch {
                importError = error.localizedDescription
            }
        }
    }

    private func openImported() {
        guard let note = importedNote else { return }
        importedNote = nil
        openNote = note
    }

    private var deleteDialogBinding: Binding<Bool> {
        Binding(get: { noteToDelete != nil && openNote == nil && !showingChronicle }, set: { if !$0 { noteToDelete = nil } })
    }

    private func createNote() {
        let note = Note()
        context.insert(note)
        try? context.save()
        newNoteID = note.persistentModelID
        openNote = note
    }

    private func delete(_ note: Note) {
        context.delete(note)
        noteToDelete = nil
        TagStore.deleteOrphans(in: context)
        try? context.save()
    }

    /// Runs when the full-screen page or chronicle closes: drops untouched new pages and sessions, and unused tags.
    private func tidyUp() {
        if let id = newNoteID, let note = notes.first(where: { $0.persistentModelID == id }), note.isBlank {
            if noteToDelete?.persistentModelID == id { noteToDelete = nil }
            context.delete(note)
        }
        for session in sessions where session.isBlank {
            context.delete(session)
        }
        newNoteID = nil
        TagStore.deleteOrphans(in: context)
        try? context.save()
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [Note.self, Tag.self, NoteImage.self], inMemory: true)
}

/// Presents the system share sheet (Save to Files, AirDrop, Print…) from the top-right corner.
enum ShareSheet {
    static func present(_ url: URL) {
        guard let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
              var presenter = scene.keyWindow?.rootViewController
        else { return }
        while let presented = presented(presenter) { presenter = presented }

        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = presenter.view
            // Roughly under the export button, left of the search field.
            popover.sourceRect = CGRect(x: presenter.view.bounds.maxX - 350, y: 70, width: 1, height: 1)
            popover.permittedArrowDirections = .up
        }
        presenter.present(sheet, animated: true)
    }

    private static func presented(_ controller: UIViewController) -> UIViewController? {
        guard let next = controller.presentedViewController, !next.isBeingDismissed else { return nil }
        return next
    }
}
