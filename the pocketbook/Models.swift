//
//  Models.swift
//  the pocketbook
//

import Foundation
import PencilKit
import SwiftData
import SwiftUI

@Model
final class Note {
    var title: String = ""
    var text: String = ""
    @Attribute(.externalStorage) var drawingData: Data = Data()
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now
    @Relationship(inverse: \Tag.notes) var tags: [Tag] = []
    var questionStateRaw: Int = 0 // QuestionState.none
    @Relationship(deleteRule: .cascade, inverse: \NoteImage.note) var images: [NoteImage] = []
    /// What the right half of the editor showed last (drawing or images); nil until the page is first opened.
    var visualModeRaw: String?
    /// Index of the attached image the gallery showed last.
    var galleryIndex: Int = 0
    /// A regular page or an entry of the session chronicle.
    var kindRaw: String = NoteKind.page.rawValue
    /// When the session was played; meaningful for sessions only.
    var playedAt: Date = Date.now

    init(title: String = "", kind: NoteKind = .page) {
        self.title = title
        self.kindRaw = kind.rawValue
    }

    var kind: NoteKind {
        NoteKind(rawValue: kindRaw) ?? .page
    }

    /// Sessions live in the chronicle, not in the grid, and cannot be linked with `@`.
    var isSession: Bool { kind == .session }

    var questionState: QuestionState {
        get { QuestionState(rawValue: questionStateRaw) ?? .none }
        set { questionStateRaw = newValue.rawValue }
    }

    /// The title as written after `@` in other notes.
    var linkTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Senza titolo" : trimmed
    }

    var drawing: PKDrawing? {
        guard !drawingData.isEmpty, let drawing = try? PKDrawing(data: drawingData),
              !drawing.strokes.isEmpty else { return nil }
        return drawing
    }

    /// Attached images, in the order they were added.
    var sortedImages: [NoteImage] {
        images.sorted { $0.createdAt < $1.createdAt }
    }

    /// A note with nothing written, drawn, attached or tagged: discarded when the editor closes.
    var isBlank: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && tags.isEmpty
            && drawing == nil
            && images.isEmpty
    }

    var sortedTags: [Tag] {
        tags.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func hasTag(_ tag: Tag) -> Bool {
        tags.contains { $0.persistentModelID == tag.persistentModelID }
    }

    /// Every whitespace-separated term must match the title, the text or a tag.
    /// Terms starting with `#` match tags only.
    func matches(_ query: String) -> Bool {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return terms.allSatisfy { term in
            if term.hasPrefix("#") {
                let tagTerm = String(term.dropFirst())
                return tagTerm.isEmpty || tags.contains { $0.name.localizedStandardContains(tagTerm) }
            }
            return title.localizedStandardContains(term)
                || text.localizedStandardContains(term)
                || tags.contains { $0.name.localizedStandardContains(term) }
        }
    }
}

enum NoteKind: String {
    case page, session
}

enum Chronicle {
    /// Sessions are numbered in the order they were played, like the chapters of a campaign.
    static func sessionNumbers(_ notes: [Note]) -> [PersistentIdentifier: Int] {
        let ordered = notes.filter(\.isSession).sorted {
            $0.playedAt != $1.playedAt ? $0.playedAt < $1.playedAt : $0.createdAt < $1.createdAt
        }
        return Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($1.persistentModelID, $0 + 1) })
    }
}

/// Giallo's hypotheses and open questions: a note can hold one, answered or not.
enum QuestionState: Int, CaseIterable, Identifiable {
    case none, open, resolved

    var id: Self { self }

    var label: String {
        switch self {
        case .none: "Nessuna domanda"
        case .open: "Domanda aperta"
        case .resolved: "Risolta"
        }
    }

    var icon: String {
        switch self {
        case .none: "questionmark.circle"
        case .open: "questionmark.circle.fill"
        case .resolved: "checkmark.circle.fill"
        }
    }
}

/// A picture attached to a note, shown next to its text and drawing.
@Model
final class NoteImage {
    @Attribute(.externalStorage) var data: Data = Data()
    var createdAt: Date = Date.now
    var note: Note?

    init(data: Data) {
        self.data = data
    }
}

@Model
final class Tag {
    @Attribute(.unique) var name: String
    /// Hue in 0...1, chosen at creation to be as far as possible from every other tag's hue.
    var hue: Double
    var notes: [Note] = []

    init(name: String, hue: Double) {
        self.name = name
        self.hue = hue
    }

    var color: Color {
        Color(hue: hue, saturation: 0.62, brightness: 0.78)
    }
}

enum TagStore {
    /// Returns the existing tag matching `rawName` (case-insensitive) or creates a new one.
    static func tag(named rawName: String, in context: ModelContext) -> Tag? {
        let name = rawName
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "#,")))
        guard !name.isEmpty else { return nil }

        let all = (try? context.fetch(FetchDescriptor<Tag>())) ?? []
        if let existing = all.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return existing
        }
        let tag = Tag(name: name, hue: nextHue(avoiding: all.map(\.hue)))
        context.insert(tag)
        return tag
    }

    /// Picks the hue that maximises the distance from every hue already in use.
    static func nextHue(avoiding used: [Double]) -> Double {
        guard !used.isEmpty else { return 0.06 } // il rosso-arancio di un panda rosso
        func distance(_ hue: Double) -> Double {
            used.map { abs($0 - hue) }.map { min($0, 1 - $0) }.min() ?? 1
        }
        let candidates = (0..<360).map { Double($0) / 360 }
        return candidates.max { distance($0) < distance($1) } ?? 0
    }

    /// Tags no longer attached to any note would otherwise pollute autocomplete forever.
    static func deleteOrphans(in context: ModelContext) {
        let all = (try? context.fetch(FetchDescriptor<Tag>())) ?? []
        for tag in all where tag.notes.isEmpty {
            context.delete(tag)
        }
    }
}
