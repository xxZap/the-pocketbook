//
//  PageSharing.swift
//  the pocketbook
//

import Foundation
import PDFKit
import PencilKit
import SwiftData
import UIKit
import UniformTypeIdentifiers

extension UTType {
    /// A `.pocketbook` file, declared in Info.plist so AirDrop and Files hand it straight to the app.
    nonisolated static let pocketbookPage = UTType(exportedAs: "io.boer.the-pocketbook.page")
}

/// A page as it travels between notebooks: inside a `.pocketbook` file, or fresh out of a PDF.
/// The optional fields arrived with version 2; pages without them become plain pages dated "now".
nonisolated struct SharedPage: Codable, Sendable {
    var title = ""
    var text = ""
    var tags: [String] = []
    var questionState = 0
    var drawing: Data?
    var images: [Data] = []
    /// `NoteKind.rawValue`: a session of the chronicle travels like a page.
    var kind: String?
    var createdAt: Date?
    var updatedAt: Date?
    var playedAt: Date?

    var isSession: Bool { kind == NoteKind.session.rawValue }
}

/// The contents of a `.pocketbook` file: one page, or a whole notebook with its chronicle.
nonisolated struct PageFile: Codable, Sendable {
    /// 2: dates and sessions. Older apps would turn sessions into pages, so they refuse it.
    static let currentVersion = 2

    var version = PageFile.currentVersion
    var pages: [SharedPage]
}

nonisolated enum ImportFailure: LocalizedError {
    case unreadable(String)
    case locked(String)
    case empty(String)
    case newerVersion(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let name): "\"\(name)\" non è un PDF né una pagina del taccuino leggibile."
        case .locked(let name): "\"\(name)\" è protetto da password."
        case .empty(let name): "\"\(name)\" non contiene né testo né pagine."
        case .newerVersion(let name): "\"\(name)\" arriva da una versione più recente del taccuino: aggiorna l'app per aprirlo."
        }
    }
}

enum PageSharing {
    /// Writes `note` to a temporary `.pocketbook` file and returns its URL.
    static func write(_ note: Note) throws -> URL {
        try write([note], named: note.displayTitle)
    }

    /// Writes `notes` (pages and sessions) to a temporary `.pocketbook` file named `name` and returns its URL.
    static func write(_ notes: [Note], named name: String) throws -> URL {
        let pages = notes.map { note in
            SharedPage(
                title: note.linkTitle,
                text: note.text,
                tags: note.sortedTags.map(\.name),
                questionState: note.questionStateRaw,
                drawing: note.drawing?.dataRepresentation(),
                images: note.sortedImages.map(\.data),
                kind: note.kindRaw,
                createdAt: note.createdAt,
                updatedAt: note.updatedAt,
                playedAt: note.isSession ? note.playedAt : nil
            )
        }
        let name = name
            .components(separatedBy: CharacterSet(charactersIn: "/\\:").union(.newlines))
            .joined(separator: "-")
            .prefix(80)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(String(name))
            .appendingPathExtension("pocketbook")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(PageFile(pages: pages)).write(to: url, options: .atomic)
        return url
    }

    /// The page or session already in the notebook that `page` would update instead of being added again:
    /// a page with the same title (links resolve by title, so it is the same page), or a session with the
    /// same title played the same day.
    static func match(for page: SharedPage, in notes: [Note]) -> Note? {
        let title = page.title.trimmingCharacters(in: .whitespacesAndNewlines)
        func sameTitle(_ note: Note) -> Bool {
            note.linkTitle.compare(title, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        if page.isSession {
            guard let played = page.playedAt ?? page.createdAt else { return nil }
            return notes.first { $0.isSession && sameTitle($0) && Calendar.current.isDate($0.playedAt, inSameDayAs: played) }
        }
        guard !title.isEmpty else { return nil }
        return notes.first { !$0.isSession && sameTitle($0) }
    }

    /// The text of a page after an update brings `incoming`: unchanged when it is already there
    /// (re-importing the same notebook), the incoming text when it only continues the existing one,
    /// otherwise the incoming text appended as a new paragraph. What was written here is never removed.
    static func mergedText(_ existing: String, _ incoming: String) -> String {
        let addition = incoming.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !addition.isEmpty else { return existing }
        let base = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { return incoming }
        if base.contains(addition) { return existing }
        if addition.hasPrefix(base) { return addition }
        return base + "\n\n" + addition
    }

    /// The text of a page after an update: `incoming` in place of `existing` when replacing (an empty
    /// incoming text never wipes a page), otherwise `mergedText`.
    static func updatedText(_ existing: String, _ incoming: String, replacing: Bool) -> String {
        guard replacing else { return mergedText(existing, incoming) }
        return incoming.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? existing : incoming
    }

    /// Adds `pages` to the notebook and returns the notes they became. Pages whose index is a key of
    /// `updates` are merged into that existing note instead of being added as new pages.
    /// With `replacingText`, their text takes the place of the existing one instead of being appended.
    /// `@links` between the incoming pages follow them when a title has to change;
    /// plain mentions of the existing pages in `linking` become `@links`.
    @discardableResult
    static func insert(_ pages: [SharedPage], updates: [Int: Note] = [:], replacingText: Bool = false,
                       linking: Set<PersistentIdentifier>, notes: [Note], in context: ModelContext) -> [Note] {
        var takenTitles = notes.filter { !$0.isSession }.map(\.linkTitle)
        var renamed: [(note: Note, from: String)] = []
        var added: [Note] = []
        let imported = pages.enumerated().map { index, page in
            // Plain mentions become links before the text lands anywhere, never towards the page itself.
            let target = updates[index]
            let mentions = Links.unlinkedMentions(in: page.text, notes: notes)
                .filter { linking.contains($0.note.persistentModelID) && $0.note.persistentModelID != target?.persistentModelID }
            let text = Links.linkify(page.text, mentions)

            if let target {
                merge(page, text: text, replacingText: replacingText, into: target, in: context)
                return target
            }

            let note: Note
            if page.isSession {
                note = Note(title: page.title, kind: .session)
                note.playedAt = page.playedAt ?? page.createdAt ?? .now
            } else {
                let title = page.title.trimmingCharacters(in: .whitespacesAndNewlines)
                note = Note(title: uniqueTitle(title, avoiding: &takenTitles))
                if note.title != title { renamed.append((note, title)) }
            }
            context.insert(note)

            note.text = text
            note.questionState = QuestionState(rawValue: page.questionState) ?? .none
            if let drawing = page.drawing, (try? PKDrawing(data: drawing)) != nil {
                note.drawingData = drawing
            }
            addTags(page.tags, to: note, in: context)
            let created = page.createdAt ?? .now
            addImages(page.images, to: note, from: created, in: context)
            note.createdAt = created
            note.updatedAt = page.updatedAt ?? created
            added.append(note)
            return note
        }

        // Only the newly added pages are link targets here: in their own notebook `@Title` meant one of them.
        for (note, oldTitle) in renamed {
            Links.rename(note, from: oldTitle, to: note.linkTitle, in: added)
        }
        return imported
    }

    /// Brings what `page` adds into an existing note: text appended (see `mergedText`) or, with
    /// `replacingText`, put in place of the old one when it is not empty; tags joined,
    /// an open or resolved question taken over. Drawing and images arrive only if the note has none,
    /// so re-importing a notebook never doubles them.
    private static func merge(_ page: SharedPage, text: String, replacingText: Bool, into note: Note, in context: ModelContext) {
        var changed = false
        let merged = updatedText(note.text, text, replacing: replacingText)
        if merged != note.text {
            note.text = merged
            changed = true
        }
        let tagCount = note.tags.count
        addTags(page.tags, to: note, in: context)
        changed = changed || note.tags.count != tagCount
        if page.questionState != QuestionState.none.rawValue, page.questionState != note.questionStateRaw {
            note.questionState = QuestionState(rawValue: page.questionState) ?? note.questionState
            changed = true
        }
        if note.drawing == nil, let drawing = page.drawing, (try? PKDrawing(data: drawing)) != nil {
            note.drawingData = drawing
            changed = true
        }
        if note.images.isEmpty, !page.images.isEmpty {
            addImages(page.images, to: note, from: .now, in: context)
            changed = true
        }
        if changed { note.updatedAt = .now }
    }

    private static func addTags(_ names: [String], to note: Note, in context: ModelContext) {
        for name in names {
            if let tag = TagStore.tag(named: name, in: context), !note.hasTag(tag) {
                note.tags.append(tag)
            }
        }
    }

    private static func addImages(_ images: [Data], to note: Note, from date: Date, in context: ModelContext) {
        for (offset, data) in images.enumerated() {
            let image = NoteImage(data: data)
            image.createdAt = date.addingTimeInterval(Double(offset) / 1000) // keeps their order
            context.insert(image)
            image.note = note
        }
    }

    /// Links resolve by title, so an imported page cannot share one with a page already here.
    private static func uniqueTitle(_ title: String, avoiding taken: inout [String]) -> String {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return title }
        var candidate = title
        var copy = 2
        while taken.contains(where: { $0.compare(candidate, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) {
            candidate = "\(title) (\(copy))"
            copy += 1
        }
        taken.append(candidate)
        return candidate
    }
}

/// Reads `.pocketbook` files and PDFs off the main thread.
nonisolated enum PageLoader {
    /// Scanned PDF pages come in as images: beyond this many the page would be unusable.
    private static let maxScannedPages = 20

    static func load(_ url: URL) throws -> [SharedPage] {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
            // Files opened from other apps are copies left in the app's Inbox.
            if url.deletingLastPathComponent().lastPathComponent == "Inbox" {
                try? FileManager.default.removeItem(at: url)
            }
        }
        let name = url.deletingPathExtension().lastPathComponent
        if url.pathExtension.lowercased() == "pdf" {
            return [try page(fromPDF: url, named: name)]
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url),
              let file = try? decoder.decode(PageFile.self, from: data)
        else { throw ImportFailure.unreadable(name) }
        guard file.version <= PageFile.currentVersion else { throw ImportFailure.newerVersion(name) }
        return file.pages.map { page in
            var page = page
            page.images = page.images.compactMap(ImageCodec.normalized)
            return page
        }
    }

    /// One notebook page per PDF: its text, plus a picture of every page that has none (scans).
    private static func page(fromPDF url: URL, named name: String) throws -> SharedPage {
        guard let document = PDFDocument(url: url) else { throw ImportFailure.unreadable(name) }
        guard !document.isLocked else { throw ImportFailure.locked(name) }

        var result = SharedPage(title: name)
        var texts: [String] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let text = unwrapped(page.string ?? "")
            if !text.isEmpty {
                texts.append(text)
            } else if result.images.count < maxScannedPages, let picture = picture(of: page) {
                result.images.append(picture)
            }
        }
        result.text = texts.joined(separator: "\n\n")
        guard !result.text.isEmpty || !result.images.isEmpty else { throw ImportFailure.empty(name) }
        return result
    }

    /// PDF text breaks at every printed line. Lines are joined back into paragraphs,
    /// taking a line much shorter than the widest one as the end of its paragraph.
    private static func unwrapped(_ raw: String) -> String {
        let lines = raw.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        let widest = lines.map(\.count).max() ?? 0
        var paragraphs: [String] = []
        var current = ""
        func endParagraph() {
            if !current.isEmpty { paragraphs.append(current) }
            current = ""
        }
        for line in lines {
            guard !line.isEmpty else {
                endParagraph()
                continue
            }
            if current.isEmpty {
                current = line
            } else if current.hasSuffix("-"), line.first?.isLowercase == true {
                current.removeLast() // a word hyphenated across two lines
                current += line
            } else {
                current += " " + line
            }
            if Double(line.count) < Double(widest) * 0.7 { endParagraph() }
        }
        endParagraph()
        return paragraphs.joined(separator: "\n")
    }

    private static func picture(of page: PDFPage) -> Data? {
        let bounds = page.bounds(for: .cropBox)
        let scale = 1000 / max(bounds.width, bounds.height, 1)
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        return page.thumbnail(of: size, for: .cropBox).jpegData(compressionQuality: 0.8)
    }
}
