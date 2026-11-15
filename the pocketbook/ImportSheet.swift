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

/// Shows what is about to be added or updated, and which existing pages its text can be linked to.
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
    /// Incoming pages (by index) that already exist here, with the note they would update.
    @State private var matches: [Int: Note] = [:]
    /// Matched pages the user chose to import as a separate copy instead.
    @State private var copies: Set<Int> = []
    /// What each matched page would change, worked out once: after importing it would read "nothing".
    @State private var changeSummaries: [Int: String] = [:]
    /// Whether the text of the matched pages replaces what they say now instead of being appended.
    @State private var replacingText = false

    var body: some View {
        NavigationStack {
            List {
                let indices = Array(pages.indices)
                let updated = indices.filter { matches[$0] != nil }
                let newPages = indices.filter { matches[$0] == nil && !pages[$0].isSession }
                let newSessions = indices.filter { matches[$0] == nil && pages[$0].isSession }
                if !updated.isEmpty {
                    Section {
                        Picker("Testo", selection: $replacingText) {
                            Text("Aggiungi in fondo").tag(false)
                            Text("Sostituisci").tag(true)
                        }
                        .pickerStyle(.segmented)
                        ForEach(updated, id: \.self) { index in
                            updateRow(for: index)
                        }
                    } header: {
                        Text(updated.count == 1 ? "Pagina già nel taccuino" : "Pagine già nel taccuino (\(updated.count))")
                    } footer: {
                        Text(replacingText
                             ? "Il testo nuovo prende il posto di quello della pagina esistente, che va perso; tag, disegni e immagini restano. Spegni l'interruttore per importarla come copia separata."
                             : "Il testo nuovo viene aggiunto in fondo alla pagina esistente, insieme ai tag; quello che c'è già non viene toccato. Spegni l'interruttore per importarla come copia separata.")
                    }
                }
                if !newPages.isEmpty {
                    Section(newPages.count == 1 ? "Nuova pagina" : "Nuove pagine (\(newPages.count))") {
                        ForEach(newPages, id: \.self) { index in
                            row(for: pages[index])
                        }
                    }
                }
                if !newSessions.isEmpty {
                    Section(newSessions.count == 1 ? "Nuova sessione della cronaca" : "Nuove sessioni della cronaca (\(newSessions.count))") {
                        ForEach(newSessions, id: \.self) { index in
                            row(for: pages[index])
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
            .task {
                matches = findMatches()
                updateChangeSummaries()
                suggestions = findSuggestions()
            }
            .onChange(of: replacingText) { updateChangeSummaries() }
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

    /// An incoming page that already exists: what it would add, and whether to update or copy.
    private func updateRow(for index: Int) -> some View {
        let page = pages[index]
        return VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: updateBinding(index)) {
                Text(page.title.isEmpty ? "Sessione" : page.title)
                    .font(.system(.headline, design: .serif))
                    .foregroundStyle(Theme.ink)
            }
            Text(copies.contains(index) ? "Verrà importata come copia separata" : changeSummaries[index] ?? "")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func updateChangeSummaries() {
        for (index, note) in matches { changeSummaries[index] = changes(from: pages[index], to: note) }
    }

    /// What updating `note` with `page` would change, in words.
    private func changes(from page: SharedPage, to note: Note) -> String {
        var parts: [String] = []
        let merged = PageSharing.updatedText(note.text, page.text, replacing: replacingText)
        if merged != note.text {
            if replacingText {
                let count = words(merged)
                parts.append(count == 1 ? "sostituisce il testo (1 parola)" : "sostituisce il testo (\(count) parole)")
            } else {
                let added = words(merged) - words(note.text)
                parts.append(added == 1 ? "aggiunge 1 parola" : "aggiunge \(max(added, 0)) parole")
            }
        }
        let newTags = page.tags.filter { name in !note.tags.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame } }
        if !newTags.isEmpty { parts.append(newTags.map { "+#" + $0 }.joined(separator: " ")) }
        if note.drawing == nil, page.drawing != nil { parts.append("aggiunge il disegno") }
        if note.images.isEmpty, !page.images.isEmpty {
            parts.append(page.images.count == 1 ? "aggiunge 1 immagine" : "aggiunge \(page.images.count) immagini")
        }
        if page.questionState != QuestionState.none.rawValue, page.questionState != note.questionStateRaw {
            parts.append((QuestionState(rawValue: page.questionState) ?? .none).label.lowercased())
        }
        return parts.isEmpty ? "Già aggiornata: nessuna modifica" : parts.joined(separator: " · ")
    }

    private func words(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    private func updateBinding(_ index: Int) -> Binding<Bool> {
        Binding(get: { !copies.contains(index) }, set: { if $0 { copies.remove(index) } else { copies.insert(index) } })
    }

    private func findMatches() -> [Int: Note] {
        var found: [Int: Note] = [:]
        for (index, page) in pages.enumerated() {
            if let note = PageSharing.match(for: page, in: notes) { found[index] = note }
        }
        return found
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
        for (index, page) in pages.enumerated() {
            // A page updating an existing one does not link to itself.
            let target = matches[index]?.persistentModelID
            for mention in Links.unlinkedMentions(in: page.text, notes: notes) where mention.note.persistentModelID != target {
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
        let updates = matches.filter { !copies.contains($0.key) }
        let imported = PageSharing.insert(pages, updates: updates, replacingText: replacingText, linking: linking, notes: notes, in: context)
        try? context.save()
        onImport(imported)
        dismiss()
    }
}
