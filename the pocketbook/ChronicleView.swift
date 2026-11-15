//
//  ChronicleView.swift
//  the pocketbook
//

import SwiftData
import SwiftUI

/// The full-screen cover opened from the chronicle card: the sessions, plus any page reached through their links.
struct ChronicleScreen: View {
    var onDelete: (Note) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var path: [Note] = []

    var body: some View {
        NavigationStack(path: $path) {
            ChronicleView(onClose: { dismiss() }, onOpenLink: { path.append($0) })
                .navigationDestination(for: Note.self) { linked in
                    if linked.isSession {
                        ChronicleView(focus: linked, onOpenLink: { path.append($0) })
                    } else {
                        NoteEditorView(
                            note: linked,
                            onClose: { dismiss() },
                            onOpenLink: { path.append($0) },
                            onDelete: { onDelete(linked) }
                        )
                    }
                }
        }
    }
}

/// Every session played, newest first, each with its summary and its `@links` to pages.
struct ChronicleView: View {
    /// The session to scroll to when opened from a page that cites it.
    var focus: Note?
    var onClose: (() -> Void)?
    var onOpenLink: (Note) -> Void

    @Environment(\.modelContext) private var context
    @Query private var allNotes: [Note]
    @State private var newSessionID: PersistentIdentifier?
    @State private var sessionToDelete: Note?

    private var sessions: [Note] {
        allNotes.filter(\.isSession).sorted {
            $0.playedAt != $1.playedAt ? $0.playedAt > $1.playedAt : $0.createdAt > $1.createdAt
        }
    }

    var body: some View {
        let sessions = sessions
        let numbers = Chronicle.sessionNumbers(allNotes)
        ScrollViewReader { scroller in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(sessions) { session in
                        SessionEntry(
                            session: session,
                            number: numbers[session.persistentModelID] ?? 0,
                            allNotes: allNotes,
                            startsFocused: session.persistentModelID == newSessionID,
                            onOpenLink: onOpenLink,
                            onDelete: { sessionToDelete = session }
                        )
                        .id(session.persistentModelID)
                        if session.persistentModelID != sessions.last?.persistentModelID {
                            ornament
                        }
                    }
                }
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .onAppear {
                guard let focus else { return }
                Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    withAnimation { scroller.scrollTo(focus.persistentModelID, anchor: .top) }
                }
            }
            .onChange(of: newSessionID) { _, id in
                guard let id else { return }
                withAnimation { scroller.scrollTo(id, anchor: .top) }
            }
        }
        .overlay { if sessions.isEmpty { emptyState } }
        .background(Theme.paper)
        .navigationTitle("Cronaca delle sessioni")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.paper, for: .navigationBar)
        .toolbar {
            if let onClose {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Chiudi", systemImage: "xmark", action: onClose)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Nuova sessione", systemImage: "plus", action: addSession)
                    .keyboardShortcut("n", modifiers: .command)
            }
        }
        .confirmationDialog("Strappare questa sessione?", isPresented: Binding(get: { sessionToDelete != nil }, set: { if !$0 { sessionToDelete = nil } }),
                            titleVisibility: .visible, presenting: sessionToDelete) { session in
            Button("Elimina sessione", role: .destructive) { delete(session) }
        } message: { _ in
            Text("Il resoconto verrà eliminato definitivamente. Le pagine citate restano.")
        }
    }

    private var ornament: some View {
        HStack(spacing: 12) {
            Rectangle().fill(Theme.leather.opacity(0.25)).frame(height: 1)
            Image(systemName: "seal")
                .font(.caption)
                .foregroundStyle(Theme.leather.opacity(0.45))
            Rectangle().fill(Theme.leather.opacity(0.25)).frame(height: 1)
        }
        .padding(.vertical, 22)
        .accessibilityHidden(true)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Nessuna sessione", systemImage: "book.closed")
                .font(.system(.title2, design: .serif))
        } description: {
            Text("Dopo ogni sessione scrivi cosa è successo e dove siete stati. Con @ citi le pagine dei luoghi e dei personaggi.")
                .font(.system(.body, design: .serif))
        } actions: {
            Button("Scrivi la prima sessione", action: addSession)
                .buttonStyle(.borderedProminent)
        }
    }

    private func addSession() {
        let session = Note(kind: .session)
        context.insert(session)
        try? context.save()
        newSessionID = session.persistentModelID
    }

    private func delete(_ session: Note) {
        context.delete(session)
        sessionToDelete = nil
        try? context.save()
    }
}

/// One session of the chronicle: number, date, an optional title and the summary.
private struct SessionEntry: View {
    @Bindable var session: Note
    let number: Int
    let allNotes: [Note]
    var startsFocused = false
    var onOpenLink: (Note) -> Void
    var onDelete: () -> Void

    @Environment(\.modelContext) private var context
    @StateObject private var linkController = LinkTextController()

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 20) {
            VStack(spacing: 0) {
                Text("SESSIONE")
                    .font(.system(.caption2, design: .serif, weight: .semibold))
                    .tracking(1.5)
                Text("\(number)")
                    .font(.system(size: 40, weight: .bold, design: .serif))
            }
            .foregroundStyle(Theme.leather)
            .frame(width: 84)
            .accessibilityElement(children: .combine)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    TextField("Titolo della sessione (facoltativo)", text: $session.title, axis: .vertical)
                        .font(.system(size: 24, weight: .bold, design: .serif))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1...2)
                    Menu {
                        Button("Elimina sessione", systemImage: "trash", role: .destructive, action: onDelete)
                    } label: {
                        Label("Altro", systemImage: "ellipsis.circle")
                            .labelStyle(.iconOnly)
                            .foregroundStyle(.secondary)
                            .frame(width: 32, height: 32)
                    }
                }
                DatePicker("Giocata il", selection: $session.playedAt, displayedComponents: .date)
                    .font(.system(.subheadline, design: .serif))
                    .foregroundStyle(.secondary)
                    .fixedSize()

                LinkedTextView(text: $session.text, notes: allNotes, controller: linkController,
                               onOpenLink: onOpenLink, scrolls: false)
                    .padding(.horizontal, -27) // the text view's own inset, so the text lines up with the title
                    .frame(minHeight: 90, alignment: .top)
                    .overlay(alignment: .topLeading) {
                        if session.text.isEmpty {
                            Text("Cosa è successo? Dove siete stati? Scrivi @ per citare un luogo o un personaggio")
                                .font(.system(size: 19, design: .serif))
                                .foregroundStyle(.tertiary)
                                .padding(.top, 20)
                                .allowsHitTesting(false)
                        }
                    }
                mentionBar
            }
        }
        .animation(.snappy(duration: 0.2), value: linkController.mention)
        .onChange(of: session.title) { session.updatedAt = .now }
        .onChange(of: session.text) { session.updatedAt = .now }
        .onChange(of: session.playedAt) { session.updatedAt = .now }
        .onAppear {
            linkController.acceptFirstSuggestion = { [weak linkController] in
                guard let mention = linkController?.mention,
                      let first = Links.suggestions(for: mention.query, excluding: session, in: allNotes).first
                else { return false }
                linkController?.completeMention(with: first.linkTitle)
                return true
            }
        }
        .task {
            guard startsFocused else { return }
            try? await Task.sleep(for: .milliseconds(350))
            linkController.textView?.becomeFirstResponder()
        }
    }

    @ViewBuilder
    private var mentionBar: some View {
        if let mention = linkController.mention {
            let suggestions = Links.suggestions(for: mention.query, excluding: session, in: allNotes)
            let canCreate = Links.canCreatePage(named: mention.query, in: allNotes)
            if !suggestions.isEmpty || canCreate {
                MentionBar(
                    query: mention.query,
                    suggestions: suggestions,
                    canCreate: canCreate,
                    onPick: { linkController.completeMention(with: $0.linkTitle) },
                    onCreate: { createLinkedPage(named: mention.query) }
                )
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    private func createLinkedPage(named query: String) {
        let name = query.trimmingCharacters(in: .whitespaces)
        context.insert(Note(title: name))
        linkController.completeMention(with: name)
    }
}

/// The chronicle as it sits first among the pages: a leather-bound cover rather than a sheet of paper.
struct ChronicleCard: View {
    let sessions: [Note]

    private var latest: Note? {
        sessions.max { $0.playedAt != $1.playedAt ? $0.playedAt < $1.playedAt : $0.createdAt < $1.createdAt }
    }

    var body: some View {
        Color.clear
            .aspectRatio(0.72, contentMode: .fit)
            .overlay { content }
            .background(Theme.leather)
            .overlay(alignment: .leading) {
                // The spine.
                Rectangle().fill(.black.opacity(0.22)).frame(width: 14)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(Theme.gilt.opacity(0.55), lineWidth: 1)
                    .padding(EdgeInsets(top: 10, leading: 22, bottom: 10, trailing: 10))
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .shadow(color: .black.opacity(0.28), radius: 7, x: 0, y: 5)
            .accessibilityElement(children: .combine)
            .accessibilityHint("Apre la cronaca delle sessioni")
    }

    private var content: some View {
        VStack(spacing: 10) {
            Image(systemName: "book.closed.fill")
                .font(.title2)
                .padding(.top, 30)
            Text("Cronaca delle sessioni")
                .font(.system(.title3, design: .serif, weight: .bold))
                .multilineTextAlignment(.center)
            Text(sessions.isEmpty ? "Ancora nessuna sessione" : sessions.count == 1 ? "1 sessione" : "\(sessions.count) sessioni")
                .font(.system(.caption, design: .serif).italic())
                .opacity(0.8)

            Spacer(minLength: 0)

            if let latest {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Ultima · \(latest.playedAt.formatted(date: .abbreviated, time: .omitted))")
                        .font(.system(.caption2, design: .serif).italic())
                        .foregroundStyle(.secondary)
                    if !latest.linkTitle.isEmpty {
                        Text(latest.linkTitle)
                            .font(.system(.subheadline, design: .serif, weight: .semibold))
                            .lineLimit(1)
                    }
                    if !latest.text.isEmpty {
                        Text(latest.text)
                            .font(.system(.caption, design: .serif))
                            .lineLimit(4)
                    }
                }
                .foregroundStyle(Theme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Theme.paper, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                .rotationEffect(.degrees(-1.2))
            }
        }
        .foregroundStyle(Theme.gilt)
        .padding(EdgeInsets(top: 10, leading: 32, bottom: 22, trailing: 20))
    }
}
