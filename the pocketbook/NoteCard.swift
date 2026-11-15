//
//  NoteCard.swift
//  the pocketbook
//

import PencilKit
import SwiftData
import SwiftUI

/// A note shown as a page of the pocketbook.
struct NoteCard: View {
    let note: Note
    let pageNumber: Int

    @State private var thumbnail: UIImage?
    @State private var photo: UIImage?

    var body: some View {
        Color.clear
            .aspectRatio(0.72, contentMode: .fit)
            .overlay(alignment: .topLeading) { content }
            .overlay(alignment: .topTrailing) { questionBadge }
            .background(RuledPaper(lineSpacing: 21, topInset: 58))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.black.opacity(0.06)))
            .shadow(color: .black.opacity(0.18), radius: 6, x: 0, y: 4)
            .task(id: ThumbnailSource(drawing: note.drawingData, firstImage: firstImage?.persistentModelID)) {
                await renderThumbnails()
            }
    }

    @ViewBuilder
    private var questionBadge: some View {
        switch note.questionState {
        case .none:
            EmptyView()
        case .open:
            Image(systemName: "questionmark.circle.fill")
                .font(.title2)
                .foregroundStyle(.white, Theme.rust)
                .padding(10)
                .accessibilityLabel("Domanda aperta")
        case .resolved:
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.secondary)
                .padding(10)
                .accessibilityLabel("Domanda risolta")
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(note.displayTitle)
                .font(.system(.title3, design: .serif, weight: .bold))
                .foregroundStyle(note.title.isEmpty ? .secondary : Theme.ink)
                .lineLimit(2)
                .frame(height: 52, alignment: .bottomLeading)

            if !note.text.isEmpty {
                Text(note.text)
                    .font(.system(.callout, design: .serif))
                    .foregroundStyle(Theme.ink.opacity(0.85))
                    .lineLimit(thumbnail == nil && photo == nil ? 9 : 4)
            }

            if thumbnail != nil || photo != nil {
                HStack(spacing: 8) {
                    if let photo {
                        Image(uiImage: photo)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                            .overlay(alignment: .bottomTrailing) { extraImagesBadge }
                    }
                    if let thumbnail {
                        Image(uiImage: thumbnail)
                            .resizable()
                            .scaledToFit()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: 120)
            }

            Spacer(minLength: 0)

            VStack(spacing: 2) {
                if !note.tags.isEmpty {
                    FlowLayout(spacing: 4) {
                        ForEach(note.sortedTags.prefix(5)) { tag in
                            TagChip(tag: tag)
                                .font(.caption)
                        }
                    }
                }

                HStack {
                    Text(note.updatedAt.formatted(date: .abbreviated, time: .omitted))
                    Spacer(minLength: 0)
                    Text("p. \(pageNumber)")
                }
                .font(.system(.caption2, design: .serif).italic())
                .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 27)
        .padding(.trailing, 8)
        .padding(.top, 4)
        .padding(.bottom, 7)
    }

    @ViewBuilder
    private var extraImagesBadge: some View {
        if note.images.count > 1 {
            Text("+\(note.images.count - 1)")
                .font(.system(.caption2, design: .serif, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Theme.ink.opacity(0.75), in: Capsule())
                .padding(4)
                .accessibilityLabel("Altre \(note.images.count - 1) immagini")
        }
    }

    /// What the thumbnails are drawn from: typing in the note must not redraw them.
    private struct ThumbnailSource: Equatable {
        let drawing: Data
        let firstImage: PersistentIdentifier?
    }

    private var firstImage: NoteImage? {
        note.images.min { $0.createdAt < $1.createdAt }
    }

    private func renderThumbnails() async {
        let drawingData = note.drawingData
        thumbnail = await Task.detached { Self.renderDrawing(drawingData) }.value

        if let data = firstImage?.data {
            photo = await Task.detached { ImageCodec.downsample(data, maxPixel: 600) }.value
        } else {
            photo = nil
        }
    }

    /// Decodes and rasterises the drawing off the main thread, in the canvas's light appearance.
    nonisolated private static func renderDrawing(_ data: Data) -> UIImage? {
        guard !data.isEmpty, let drawing = try? PKDrawing(data: data), !drawing.strokes.isEmpty else { return nil }
        let bounds = drawing.bounds.insetBy(dx: -8, dy: -8)
        let scale = min(2, 400 / max(bounds.width, bounds.height, 1))
        var image: UIImage?
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            image = drawing.image(from: bounds, scale: scale)
        }
        return image
    }
}
