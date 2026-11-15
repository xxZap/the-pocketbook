//
//  Links.swift
//  the pocketbook
//

import Foundation
import SwiftData

/// An `@Title` reference inside a note's text. `range` is in UTF-16 units and includes the `@`.
struct NoteLink {
    let range: NSRange
    let note: Note
}

/// The `@query` the user is typing right now, up to the caret.
struct Mention: Equatable {
    let range: NSRange
    let query: String
}

enum Links {
    /// Finds `@Title` references to any of `notes`, preferring the longest matching title.
    /// `titleOverride` lets a caller resolve one note under a different title (used when renaming).
    static func find(in text: String, notes: [Note], titleOverride: (Note, String)? = nil) -> [NoteLink] {
        guard text.contains("@") else { return [] }
        let targets = notes
            .filter { !$0.isSession }
            .map { note -> (String, Note) in
                if let (target, title) = titleOverride, target.persistentModelID == note.persistentModelID {
                    return (title, note)
                }
                return (note.linkTitle, note)
            }
            .filter { !$0.0.isEmpty }
            .sorted { ($0.0 as NSString).length > ($1.0 as NSString).length }

        let ns = text as NSString
        var links: [NoteLink] = []
        var searchStart = 0
        while searchStart < ns.length {
            let at = ns.range(of: "@", range: NSRange(location: searchStart, length: ns.length - searchStart))
            guard at.location != NSNotFound else { break }
            searchStart = at.location + 1
            guard isBoundary(ns, at.location - 1) else { continue }

            for (title, note) in targets {
                let length = (title as NSString).length
                let candidate = NSRange(location: at.location + 1, length: length)
                guard NSMaxRange(candidate) <= ns.length,
                      ns.substring(with: candidate).compare(title, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame,
                      isBoundary(ns, NSMaxRange(candidate))
                else { continue }
                links.append(NoteLink(range: NSRange(location: at.location, length: length + 1), note: note))
                searchStart = NSMaxRange(candidate)
                break
            }
        }
        return links
    }

    /// The `@query` ending at `caret`, if the user is in the middle of typing one.
    static func activeMention(in text: String, caret: Int, notes: [Note]) -> Mention? {
        let ns = text as NSString
        guard caret > 0, caret <= ns.length else { return nil }
        var index = caret - 1
        let maxLookBack = 40
        while index >= 0, caret - index <= maxLookBack {
            let char = ns.character(at: index)
            if char == 10 || char == 13 { return nil } // a mention never spans lines
            if char == 64 /* @ */ {
                guard isBoundary(ns, index - 1) else { return nil }
                let range = NSRange(location: index, length: caret - index)
                let query = ns.substring(with: NSRange(location: index + 1, length: caret - index - 1))
                if query.first?.isWhitespace == true { return nil }
                // Already a finished link that the caret has reached or passed: nothing to suggest.
                let lineEnd = ns.lineRange(for: NSRange(location: index, length: 0))
                let fromAt = ns.substring(with: NSRange(location: index, length: NSMaxRange(lineEnd) - index))
                if let link = find(in: fromAt, notes: notes).first, link.range.location == 0,
                   link.range.length <= range.length {
                    return nil
                }
                return Mention(range: range, query: query)
            }
            index -= 1
        }
        return nil
    }

    /// Pages that can complete the `@query` being typed in `current`, best matches first.
    static func suggestions(for query: String, excluding current: Note?, in notes: [Note]) -> [Note] {
        let query = query.trimmingCharacters(in: .whitespaces)
        return notes
            .filter { !$0.isSession && $0.persistentModelID != current?.persistentModelID && !$0.linkTitle.isEmpty }
            .filter { query.isEmpty || $0.linkTitle.localizedStandardContains(query) }
            .sorted { lhs, rhs in
                let l = lhs.linkTitle.lowercased().hasPrefix(query.lowercased())
                let r = rhs.linkTitle.lowercased().hasPrefix(query.lowercased())
                return l != r ? l : lhs.updatedAt > rhs.updatedAt
            }
            .prefix(8)
            .map { $0 }
    }

    /// Whether `@query` could become a new page: short, and not the title of an existing one.
    static func canCreatePage(named query: String, in notes: [Note]) -> Bool {
        let name = query.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.split(separator: " ").count <= 5 else { return false }
        return !notes.contains {
            !$0.isSession && $0.linkTitle.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
    }

    /// Notes whose text links to `note`.
    static func backlinks(to note: Note, in notes: [Note]) -> [Note] {
        let title = note.linkTitle
        guard !title.isEmpty else { return [] }
        return notes.filter { other in
            other.persistentModelID != note.persistentModelID
                && other.text.localizedCaseInsensitiveContains("@" + title)
                && find(in: other.text, notes: notes).contains { $0.note.persistentModelID == note.persistentModelID }
        }
    }

    /// Rewrites every `@oldTitle` that pointed at `target` so links survive a rename.
    static func rename(_ target: Note, from oldTitle: String, to newTitle: String, in notes: [Note]) {
        guard !oldTitle.isEmpty, !newTitle.isEmpty, oldTitle != newTitle else { return }
        for note in notes where note.text.localizedCaseInsensitiveContains("@" + oldTitle) {
            let links = find(in: note.text, notes: notes, titleOverride: (target, oldTitle))
                .filter { $0.note.persistentModelID == target.persistentModelID }
            guard !links.isEmpty else { continue }
            let text = NSMutableString(string: note.text)
            for link in links.reversed() {
                text.replaceCharacters(in: link.range, with: "@" + newTitle)
            }
            note.text = text as String
        }
    }

    /// Note titles written as plain words, not yet as `@Title`: what an imported text can be linked to.
    /// Where two titles overlap the longer one wins.
    static func unlinkedMentions(in text: String, notes: [Note]) -> [NoteLink] {
        let ns = text as NSString
        let linked = find(in: text, notes: notes).map(\.range)
        var found: [NoteLink] = []
        for note in notes where !note.isSession {
            let title = note.linkTitle
            // One or two letters would match half the words of any text.
            guard (title as NSString).length >= 3 else { continue }
            var search = NSRange(location: 0, length: ns.length)
            while search.length > 0 {
                let match = ns.range(of: title, options: [.caseInsensitive, .diacriticInsensitive], range: search)
                guard match.location != NSNotFound else { break }
                search = NSRange(location: NSMaxRange(match), length: ns.length - NSMaxRange(match))
                guard isBoundary(ns, match.location - 1), isBoundary(ns, NSMaxRange(match)),
                      match.location == 0 || ns.character(at: match.location - 1) != 64 /* @ */,
                      !linked.contains(where: { NSIntersectionRange($0, match).length > 0 })
                else { continue }
                found.append(NoteLink(range: match, note: note))
            }
        }

        var mentions: [NoteLink] = []
        var end = 0
        let ordered = found.sorted {
            $0.range.location != $1.range.location ? $0.range.location < $1.range.location : $0.range.length > $1.range.length
        }
        for mention in ordered where mention.range.location >= end {
            mentions.append(mention)
            end = NSMaxRange(mention.range)
        }
        return mentions
    }

    /// Rewrites each of `mentions` (ranges in `text`) as an `@Title` link.
    static func linkify(_ text: String, _ mentions: [NoteLink]) -> String {
        let result = NSMutableString(string: text)
        for mention in mentions.sorted(by: { $0.range.location > $1.range.location }) {
            result.replaceCharacters(in: mention.range, with: "@" + mention.note.linkTitle)
        }
        return result as String
    }

    /// True at the text edges and next to anything that is not a letter or digit.
    private static func isBoundary(_ ns: NSString, _ index: Int) -> Bool {
        guard index >= 0, index < ns.length else { return true }
        guard let scalar = Unicode.Scalar(ns.character(at: index)) else { return true }
        return !CharacterSet.alphanumerics.contains(scalar)
    }
}
