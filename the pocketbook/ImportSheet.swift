//
//  ImportSheet.swift
//  the pocketbook
//

import SwiftData
import SwiftUI

/// Pages read from a file, waiting for the user to confirm the import.
struct PendingImport: Identifiable {
    let id = UUID()
    let pages: [SharedPage]
}

/// Shows what is about to be added and which existing pages its text can be linked to.
struct ImportSheet: View {
    let pages: [SharedPage]
    var onImport: ([Note]) -> Void

    /// An existing page named in the incoming text, and how many times.
    private struct Suggestion: Identifiable {
        let note: Note
        let count: Int
        var id: PersistentIdentifier { note.persistentModelID }
    }

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var notes: [Note]
    @State private var suggestions: [Suggestion] = []
    @State private var skipped: Set<PersistentIdentifier> = []

    var body: some View {
        NavigationStack {
            List {
                let newPages = pages.filter { !$0.isSession }
                let newSessions = pages.filter(\.isSession)
                if !newPages.isEmpty {
                    Section(newPages.count == 1 ? "Nuova pagina" : "Nuove pagine (\(newPages.count))") {
                        ForEach(Array(newPages.enumerated()), id: \.offset) { _, page in
                            row(for: page)
                        }
                    }
                }
                if !newSessions.isEmpty {
                    Section(newSessions.count == 1 ? "Nuova sessione della cronaca" : "Nuove sessioni della cronaca (\(newSessions.count))") {
                        ForEach(Array(newSessions.enumerated()), id: \.offset) { _, page in
                            row(for: page)
                        }
                    }
                }
                if !suggestions.isEmpty {
                    Section {
                        ForEach(suggestions) { suggestion in
                            Toggle(isOn: linkBinding(suggestion.id)) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("@" + suggestion.note.linkTitle)
                                        .font(.system(.body, design: .serif))
                                        .foregroundStyle(Theme.rust)
                                    Text(suggestion.count == 1 ? "citata 1 volta" : "citata \(suggestion.count) volte")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    } header: {
                        Text("Collegamenti trovati")
                    } footer: {
                        Text("Il testo nomina pagine che hai già: dove compare il loro titolo verrà scritto un @collegamento.")
                    }
                }
            }
            .navigationTitle("Importa nel taccuino")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Importa", action: importPages)
                }
            }
            .task { suggestions = findSuggestions() }
        }
    }

    private func row(for page: SharedPage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(page.title.isEmpty ? (page.isSession ? "Sessione" : "Senza titolo") : page.title)
                .font(.system(.headline, design: .serif))
                .foregroundStyle(Theme.ink)
            Text(summary(of: page))
                .font(.caption)
                .foregroundStyle(.secondary)
            if !page.text.isEmpty {
                Text(page.text)
                    .font(.system(.subheadline, design: .serif))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .padding(.vertical, 2)
    }

    private func summary(of page: SharedPage) -> String {
        let words = page.text.split(whereSeparator: \.isWhitespace).count
        var parts: [String] = []
        if let date = page.isSession ? page.playedAt : page.createdAt {
            parts.append(date.formatted(date: .abbreviated, time: .omitted))
        }
        parts.append(words == 1 ? "1 parola" : "\(words) parole")
        if !page.images.isEmpty { parts.append(page.images.count == 1 ? "1 immagine" : "\(page.images.count) immagini") }
        if page.drawing != nil { parts.append("disegno") }
        if !page.tags.isEmpty { parts.append(page.tags.map { "#" + $0 }.joined(separator: " ")) }
        return parts.joined(separator: " · ")
    }

    private func findSuggestions() -> [Suggestion] {
        var counts: [PersistentIdentifier: Suggestion] = [:]
        for page in pages {
            for mention in Links.unlinkedMentions(in: page.text, notes: notes) {
                let id = mention.note.persistentModelID
                counts[id] = Suggestion(note: mention.note, count: (counts[id]?.count ?? 0) + 1)
            }
        }
        return counts.values.sorted {
            $0.count != $1.count ? $0.count > $1.count
                : $0.note.linkTitle.localizedStandardCompare($1.note.linkTitle) == .orderedAscending
        }
    }

    private func linkBinding(_ id: PersistentIdentifier) -> Binding<Bool> {
        Binding(get: { !skipped.contains(id) }, set: { if $0 { skipped.remove(id) } else { skipped.insert(id) } })
    }

    private func importPages() {
        let linking = Set(suggestions.map(\.id)).subtracting(skipped)
        let imported = PageSharing.insert(pages, linking: linking, notes: notes, in: context)
        try? context.save()
        onImport(imported)
        dismiss()
    }
}
