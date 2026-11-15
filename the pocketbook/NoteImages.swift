//
//  NoteImages.swift
//  the pocketbook
//

import ImageIO
import SwiftData
import SwiftUI
import UIKit

nonisolated enum ImageCodec {
    /// Decodes `data` no larger than `maxPixel` on its longest side, already upright.
    static func downsample(_ data: Data, maxPixel: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }

    /// What gets stored: photos straight from the library are far larger than a page needs.
    static func normalized(_ data: Data) -> Data? {
        guard let image = downsample(data, maxPixel: 2400), let cgImage = image.cgImage else { return nil }
        let opaque: Set<CGImageAlphaInfo> = [.none, .noneSkipFirst, .noneSkipLast]
        return opaque.contains(cgImage.alphaInfo) ? image.jpegData(compressionQuality: 0.85) : image.pngData()
    }
}

/// An attached image, decoded off the main thread at the size it is shown.
struct NoteImageView: View {
    let image: NoteImage
    var maxPixel: CGFloat = 1600

    @State private var rendered: UIImage?

    var body: some View {
        Group {
            if let rendered {
                Image(uiImage: rendered)
                    .resizable()
                    .scaledToFit()
            } else {
                Rectangle()
                    .fill(Theme.rule)
                    .aspectRatio(4 / 3, contentMode: .fit)
            }
        }
        .task(id: image.persistentModelID) {
            let data = image.data
            let maxPixel = maxPixel
            rendered = await Task.detached { ImageCodec.downsample(data, maxPixel: maxPixel) }.value
        }
    }
}

/// The images of a page, one per swipe; a tap opens them full screen.
struct ImageGallery: View {
    let images: [NoteImage]
    @Binding var selection: Int
    var onDelete: (NoteImage) -> Void

    @State private var viewed: NoteImage?

    var body: some View {
        TabView(selection: $selection) {
            ForEach(Array(images.enumerated()), id: \.element.persistentModelID) { index, image in
                tile(image)
                    .padding(.horizontal, 28)
                    .padding(.top, 24)
                    .padding(.bottom, images.count > 1 ? 52 : 24)
                    .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: images.count > 1 ? .always : .never))
        .indexViewStyle(.page(backgroundDisplayMode: .always))
        .fullScreenCover(item: $viewed) { image in
            ImageViewer(images: images, selection: image.persistentModelID, onDelete: onDelete)
        }
    }

    private func tile(_ image: NoteImage) -> some View {
        Button {
            // Puts away the keyboard, which would float over the viewer.
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            viewed = image
        } label: {
            NoteImageView(image: image, maxPixel: 1600)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(.black.opacity(0.08)))
                .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Immagine allegata")
        .contextMenu {
            Button("Elimina immagine", systemImage: "trash", role: .destructive) { onDelete(image) }
        }
    }
}

/// Full-screen look at the attached images, one per swipe.
struct ImageViewer: View {
    let images: [NoteImage]
    @State var selection: PersistentIdentifier
    var onDelete: (NoteImage) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TabView(selection: $selection) {
                ForEach(images) { image in
                    NoteImageView(image: image, maxPixel: 2400)
                        .padding(20)
                        .tag(image.persistentModelID)
                }
            }
            .tabViewStyle(.page)
            .indexViewStyle(.page(backgroundDisplayMode: .always))
            .background(Theme.paper)
            .toolbarBackground(Theme.paper, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Chiudi", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Elimina immagine", systemImage: "trash", role: .destructive) {
                        guard let image = images.first(where: { $0.persistentModelID == selection }) else { return }
                        dismiss()
                        onDelete(image)
                    }
                }
            }
        }
    }
}
