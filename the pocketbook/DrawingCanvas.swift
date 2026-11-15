//
//  DrawingCanvas.swift
//  the pocketbook
//

import Combine
import PencilKit
import SwiftUI

/// Lets SwiftUI buttons reach the underlying canvas.
final class CanvasController: ObservableObject {
    weak var canvas: PKCanvasView?

    func showTools() {
        canvas?.becomeFirstResponder()
    }

    func hideTools() {
        canvas?.resignFirstResponder()
    }

    /// Wipes the page; the palette's undo arrow brings the drawing back.
    func clear() {
        guard let canvas, !canvas.drawing.strokes.isEmpty else { return }
        replaceDrawing(with: PKDrawing(), on: canvas)
    }

    private func replaceDrawing(with drawing: PKDrawing, on canvas: PKCanvasView) {
        let previous = canvas.drawing
        canvas.undoManager?.registerUndo(withTarget: self) { [weak canvas] controller in
            guard let canvas else { return }
            controller.replaceDrawing(with: previous, on: canvas)
        }
        canvas.undoManager?.setActionName("Pulisci disegno")
        canvas.drawing = drawing
    }
}

/// PencilKit renders a drawing assigned before the canvas has a size only in fragments,
/// so the saved drawing is loaded on the first layout pass with real bounds.
final class PageCanvasView: PKCanvasView {
    var pendingDrawing: PKDrawing?
    var isLoadingDrawing = false

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        if let drawing = pendingDrawing {
            pendingDrawing = nil
            isLoadingDrawing = true
            self.drawing = drawing
            isLoadingDrawing = false
        }
        fitContentToDrawing()
    }

    /// The canvas shrinks with the page (split layout, rotation): strokes left outside stay reachable by scrolling.
    private func fitContentToDrawing() {
        var needed = bounds.size
        if !drawing.strokes.isEmpty {
            needed.width = max(needed.width, drawing.bounds.maxX + 24)
            needed.height = max(needed.height, drawing.bounds.maxY + 24)
        }
        if contentSize != needed { contentSize = needed }
    }
}

struct DrawingCanvas: UIViewRepresentable {
    @Binding var data: Data
    let controller: CanvasController

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PageCanvasView()
        canvas.drawingPolicy = .anyInput // dito e Apple Pencil
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.overrideUserInterfaceStyle = .light
        canvas.tool = PKInkingTool(.pen, color: .black, width: 3)
        canvas.pendingDrawing = try? PKDrawing(data: data)
        canvas.delegate = context.coordinator

        let toolPicker = context.coordinator.toolPicker
        toolPicker.setVisible(true, forFirstResponder: canvas)
        toolPicker.addObserver(canvas)
        controller.canvas = canvas
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        context.coordinator.parent = self
    }

    static func dismantleUIView(_ canvas: PKCanvasView, coordinator: Coordinator) {
        coordinator.toolPicker.setVisible(false, forFirstResponder: canvas)
        coordinator.toolPicker.removeObserver(canvas)
        canvas.resignFirstResponder()
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var parent: DrawingCanvas
        let toolPicker = PKToolPicker()

        init(_ parent: DrawingCanvas) {
            self.parent = parent
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            if (canvasView as? PageCanvasView)?.isLoadingDrawing == true { return }
            parent.data = canvasView.drawing.dataRepresentation()
        }

        // Show the tool palette as soon as the user starts drawing.
        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
            if !canvasView.isFirstResponder {
                canvasView.becomeFirstResponder()
            }
        }
    }
}
