//
//  TagViews.swift
//  the pocketbook
//

import SwiftData
import SwiftUI

struct TagChip: View {
    let tag: Tag
    var isSelected = false
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(tag.color)
                .frame(width: 8, height: 8)
            Text(tag.name)
                .lineLimit(1)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.bold))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Rimuovi \(tag.name)")
            }
        }
        .font(.system(.subheadline, design: .serif))
        .foregroundStyle(isSelected ? .white : Theme.ink)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(isSelected ? tag.color : tag.color.opacity(0.16), in: Capsule())
        .overlay(Capsule().strokeBorder(tag.color.opacity(0.7), lineWidth: 1))
    }
}

/// Tags of a note with free-text entry and autocomplete on existing tags.
struct TagEditor: View {
    @Bindable var note: Note
    @Environment(\.modelContext) private var context
    @Query(sort: \Tag.name) private var allTags: [Tag]
    @State private var input = ""
    @FocusState private var isFocused: Bool

    private var query: String {
        input.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "#")))
    }

    private var suggestions: [Tag] {
        allTags
            .filter { !note.hasTag($0) && (query.isEmpty || $0.name.localizedStandardContains(query)) }
            .sorted { lhs, rhs in
                // Prefix matches first, then alphabetical.
                let l = lhs.name.lowercased().hasPrefix(query.lowercased())
                let r = rhs.name.lowercased().hasPrefix(query.lowercased())
                return l != r ? l : lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FlowLayout(spacing: 6) {
                ForEach(note.sortedTags) { tag in
                    TagChip(tag: tag) { remove(tag) }
                }
                TextField("Aggiungi tag…", text: $input)
                    .font(.system(.subheadline, design: .serif))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .focused($isFocused)
                    .frame(minWidth: 140, maxWidth: 220)
                    .padding(.vertical, 4)
                    .onSubmit { addTyped() }
                    .onChange(of: input) { _, newValue in
                        // Rewriting the field while UIKit is still delivering the keystroke drops
                        // the next input, so split on the following run loop turn.
                        if newValue.contains(",") {
                            Task { @MainActor in commitCommaSeparated() }
                        }
                    }
            }

            if isFocused && !suggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        Image(systemName: "text.badge.plus")
                            .foregroundStyle(.secondary)
                        ForEach(suggestions) { tag in
                            Button { add(tag) } label: { TagChip(tag: tag) }
                                .buttonStyle(.plain)
                        }
                    }
                }
                .transition(.opacity)
            }
        }
        .animation(.snappy, value: isFocused)
        .onDisappear {
            // Closing the page with a half-typed tag keeps it rather than losing it.
            if !query.isEmpty { addTyped() }
        }
    }

    private func addTyped() {
        if let tag = TagStore.tag(named: input, in: context) { add(tag) }
        input = ""
        isFocused = true
    }

    /// A comma closes the tags before it; whatever follows it stays in the field.
    private func commitCommaSeparated() {
        guard let lastComma = input.lastIndex(of: ",") else { return }
        let completed = input[..<lastComma].split(separator: ",").map(String.init)
        input = String(input[input.index(after: lastComma)...])
        for name in completed {
            if let tag = TagStore.tag(named: name, in: context) { add(tag, clearingInput: false) }
        }
    }

    private func add(_ tag: Tag, clearingInput: Bool = true) {
        if clearingInput { input = "" }
        guard !note.hasTag(tag) else { return }
        note.tags.append(tag)
        note.updatedAt = .now
    }

    private func remove(_ tag: Tag) {
        note.tags.removeAll { $0.persistentModelID == tag.persistentModelID }
        note.updatedAt = .now
    }
}

/// Lays out children left to right, wrapping onto new lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].indices.isEmpty ? size.width : size.width + spacing
            if rows[rows.count - 1].width + needed > maxWidth, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            let isFirst = rows[rows.count - 1].indices.isEmpty
            rows[rows.count - 1].indices.append(index)
            rows[rows.count - 1].width += isFirst ? size.width : size.width + spacing
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}
