//
//  PDFExporter.swift
//  the pocketbook
//

import PencilKit
import SwiftData
import SwiftUI
import UIKit

/// Renders notes into an A4 PDF: a cover with the index, then every note on its own pages.
@MainActor
struct PDFExporter {
    /// The notes to export, in notebook order.
    let notes: [Note]
    /// Every note, so `@links` to pages outside the export are still highlighted.
    let allNotes: [Note]
    /// Notebook page numbers ("p. 12"), as shown in the grid.
    let pageNumbers: [PersistentIdentifier: Int]
    /// Sessions of the chronicle to print before the pages, in the order they were played.
    var sessions: [Note] = []

    private let pageRect = CGRect(x: 0, y: 0, width: 595, height: 842)
    private let margin: CGFloat = 56
    private var contentWidth: CGFloat { pageRect.width - margin * 2 }
    private var contentBottom: CGFloat { pageRect.height - margin }

    private let ink = UIColor(Theme.ink)
    private let rust = UIColor(Theme.rust)
    private let faint = UIColor.secondaryLabel.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))

    private func serif(_ size: CGFloat, weight: UIFont.Weight = .regular, italic: Bool = false) -> UIFont {
        var descriptor = UIFont.systemFont(ofSize: size, weight: weight).fontDescriptor
        descriptor = descriptor.withDesign(.serif) ?? descriptor
        if italic, let slanted = descriptor.withSymbolicTraits(descriptor.symbolicTraits.union(.traitItalic)) {
            descriptor = slanted
        }
        return UIFont(descriptor: descriptor, size: size)
    }

    /// Writes the PDF to a temporary file and returns its URL.
    func write() throws -> URL {
        let stamp = Date.now.formatted(.iso8601.year().month().day())
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Taccuino di Giallo \(stamp).pdf")

        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextTitle as String: "Il taccuino di Giallo",
            kCGPDFContextCreator as String: "the pocketbook",
        ]
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect, format: format)
        var failure: Error?
        // Ink and system colors must resolve as on paper, whatever the device appearance.
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            do {
                try renderer.writePDF(to: url) { context in
                    var page = PageState(context: context)
                    drawCover(&page)
                    drawChronicle(&page)
                    for note in notes {
                        drawNote(note, &page)
                    }
                }
            } catch {
                failure = error
            }
        }
        if let failure { throw failure }
        return url
    }

    // MARK: Pages

    private struct PageState {
        let context: UIGraphicsPDFRendererContext
        var number = 0
        var y: CGFloat = 0
    }

    private func newPage(_ page: inout PageState, runningTitle: String?) {
        page.context.beginPage()
        page.number += 1
        page.y = margin

        let footer = NSAttributedString(string: "\(page.number)", attributes: [.font: serif(9, italic: true), .foregroundColor: faint])
        footer.draw(at: CGPoint(x: pageRect.midX - footer.size().width / 2, y: pageRect.height - margin / 2 - 6))

        if let runningTitle {
            let header = NSAttributedString(string: runningTitle, attributes: [.font: serif(9, italic: true), .foregroundColor: faint])
            header.draw(at: CGPoint(x: margin, y: margin / 2 - 2))
        }
    }

    /// Draws `text` from the current position, continuing onto new pages as needed.
    private func drawFlowing(_ text: NSAttributedString, _ page: inout PageState, runningTitle: String) {
        guard text.length > 0 else { return }
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)

        while true {
            let container = NSTextContainer(size: CGSize(width: contentWidth, height: contentBottom - page.y))
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            let glyphs = layout.glyphRange(for: container)
            let origin = CGPoint(x: margin, y: page.y)
            layout.drawBackground(forGlyphRange: glyphs, at: origin)
            layout.drawGlyphs(forGlyphRange: glyphs, at: origin)

            if NSMaxRange(glyphs) >= layout.numberOfGlyphs {
                page.y += layout.usedRect(for: container).height
                return
            }
            // Nothing fits even on a fresh page: stop rather than loop forever.
            if glyphs.length == 0, page.y == margin { return }
            newPage(&page, runningTitle: runningTitle)
        }
    }

    // MARK: Cover

    private func drawCover(_ page: inout PageState) {
        newPage(&page, runningTitle: nil)
        page.y = 180

        let title = NSAttributedString(string: "Il taccuino di Giallo", attributes: [.font: serif(34, weight: .bold), .foregroundColor: ink])
        title.draw(at: CGPoint(x: margin, y: page.y))
        page.y += title.size().height + 8

        let count = notes.count == 1 ? "1 pagina" : "\(notes.count) pagine"
        let subtitle = NSAttributedString(
            string: "\(count) · esportato il \(Date.now.formatted(date: .long, time: .shortened))",
            attributes: [.font: serif(12, italic: true), .foregroundColor: faint]
        )
        subtitle.draw(at: CGPoint(x: margin, y: page.y))
        page.y += subtitle.size().height + 40

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.tabStops = [NSTextTab(textAlignment: .left, location: 44)]
        paragraph.headIndent = 44
        let index = NSMutableAttributedString()
        for note in notes {
            let number = pageNumbers[note.persistentModelID].map { "p. \($0)" } ?? ""
            index.append(NSAttributedString(string: "\(number)\t", attributes: [.font: serif(10, italic: true), .foregroundColor: faint, .paragraphStyle: paragraph]))
            index.append(NSAttributedString(string: note.displayTitle, attributes: [.font: serif(12), .foregroundColor: ink, .paragraphStyle: paragraph]))
            if note.questionState == .open {
                index.append(NSAttributedString(string: "  ?", attributes: [.font: serif(12, weight: .bold), .foregroundColor: rust]))
            }
            index.append(NSAttributedString(string: "\n", attributes: [.font: serif(12), .paragraphStyle: paragraph]))
        }
        drawFlowing(index, &page, runningTitle: "Indice")
    }

    // MARK: Chronicle

    private func drawChronicle(_ page: inout PageState) {
        guard !sessions.isEmpty else { return }
        let running = "Cronaca delle sessioni"
        newPage(&page, runningTitle: nil)
        let title = NSAttributedString(string: running, attributes: [.font: serif(24, weight: .bold), .foregroundColor: ink])
        drawFlowing(title, &page, runningTitle: running)
        page.y += 18

        for (offset, session) in sessions.enumerated() {
            let heading = NSMutableAttributedString(string: "Sessione \(offset + 1)", attributes: [
                .font: serif(15, weight: .bold), .foregroundColor: rust,
            ])
            if !session.linkTitle.isEmpty {
                heading.append(NSAttributedString(string: " · \(session.linkTitle)", attributes: [.font: serif(15, weight: .bold), .foregroundColor: ink]))
            }
            heading.append(NSAttributedString(string: "\n\(session.playedAt.formatted(date: .long, time: .omitted))\n", attributes: [
                .font: serif(9, italic: true), .foregroundColor: faint,
            ]))
            // Keep a heading together with the start of its text.
            if page.y > contentBottom - 90 { newPage(&page, runningTitle: running) }
            drawFlowing(heading, &page, runningTitle: running)
            page.y += 4
            drawFlowing(body(of: session), &page, runningTitle: running)
            page.y += 22
        }
    }

    // MARK: Notes

    private func drawNote(_ note: Note, _ page: inout PageState) {
        let running = note.displayTitle
        newPage(&page, runningTitle: nil)

        // Notebook page number, top right.
        if let number = pageNumbers[note.persistentModelID] {
            let label = NSAttributedString(string: "p. \(number)", attributes: [.font: serif(10, italic: true), .foregroundColor: faint])
            label.draw(at: CGPoint(x: pageRect.width - margin - label.size().width, y: margin / 2 - 2))
        }

        let header = NSMutableAttributedString(string: note.displayTitle + "\n", attributes: [
            .font: serif(24, weight: .bold),
            .foregroundColor: note.title.isEmpty ? faint : ink,
        ])

        if !note.tags.isEmpty {
            for (offset, tag) in note.sortedTags.enumerated() {
                let color = UIColor(tag.color)
                if offset > 0 { header.append(NSAttributedString(string: "   ")) }
                header.append(NSAttributedString(string: "● ", attributes: [.font: serif(10), .foregroundColor: color]))
                header.append(NSAttributedString(string: tag.name, attributes: [.font: serif(11), .foregroundColor: ink]))
            }
            header.append(NSAttributedString(string: "\n"))
        }

        var meta = "Creata \(note.createdAt.formatted(date: .abbreviated, time: .shortened)) · modificata \(note.updatedAt.formatted(date: .abbreviated, time: .shortened))"
        if note.questionState != .none { meta = note.questionState.label + " · " + meta }
        header.append(NSAttributedString(string: meta, attributes: [
            .font: serif(9, italic: true),
            .foregroundColor: note.questionState == .open ? rust : faint,
        ]))

        let spacing = NSMutableParagraphStyle()
        spacing.paragraphSpacing = 6
        header.addAttribute(.paragraphStyle, value: spacing, range: NSRange(location: 0, length: header.length))
        drawFlowing(header, &page, runningTitle: running)

        // Rule under the header.
        page.y += 10
        let rule = UIBezierPath(rect: CGRect(x: margin, y: page.y, width: contentWidth, height: 0.6))
        rust.withAlphaComponent(0.5).setFill()
        rule.fill()
        page.y += 16

        drawFlowing(body(of: note), &page, runningTitle: running)
        drawDrawing(of: note, &page, runningTitle: running)
        drawImages(of: note, &page, runningTitle: running)
    }

    private func body(of note: Note) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.paragraphSpacing = 6
        let text = NSMutableAttributedString(string: note.text, attributes: [
            .font: serif(12), .foregroundColor: ink, .paragraphStyle: paragraph,
        ])
        for link in Links.find(in: note.text, notes: allNotes) {
            text.addAttributes([.foregroundColor: rust, .underlineStyle: NSUnderlineStyle.single.rawValue], range: link.range)
        }
        return text
    }

    private func drawDrawing(of note: Note, _ page: inout PageState, runningTitle: String) {
        guard let drawing = note.drawing else { return }
        let bounds = drawing.bounds.insetBy(dx: -12, dy: -12)
        place(drawing.image(from: bounds, scale: 2), sized: bounds.size, &page, runningTitle: runningTitle)
    }

    private func drawImages(of note: Note, _ page: inout PageState, runningTitle: String) {
        for attachment in note.sortedImages {
            guard let image = ImageCodec.downsample(attachment.data, maxPixel: 1600) else { continue }
            place(image, sized: image.size, &page, runningTitle: runningTitle)
        }
    }

    /// Draws `image` centred below the current position, scaled down to fit a page.
    private func place(_ image: UIImage, sized natural: CGSize, _ page: inout PageState, runningTitle: String) {
        let maxHeight = contentBottom - margin
        let scale = min(1, contentWidth / natural.width, maxHeight / natural.height)
        let size = CGSize(width: natural.width * scale, height: natural.height * scale)

        page.y += 20
        if page.y + size.height > contentBottom {
            newPage(&page, runningTitle: runningTitle)
        }
        image.draw(in: CGRect(origin: CGPoint(x: margin + (contentWidth - size.width) / 2, y: page.y), size: size))
        page.y += size.height
    }
}
