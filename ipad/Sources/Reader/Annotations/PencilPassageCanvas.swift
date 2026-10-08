import PencilKit
import SwiftUI

struct PencilPassageCanvas: UIViewRepresentable {
  @Binding var drawing: PKDrawing
  let mode: PencilReaderMode
  let fixtureGeneration: Int

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeUIView(context: Context) -> PKCanvasView {
    let canvas = PKCanvasView()
    canvas.delegate = context.coordinator
    canvas.backgroundColor = .secondarySystemBackground
    canvas.isOpaque = true
    canvas.isScrollEnabled = false
    canvas.contentSize = CGSize(width: 640, height: 360)
    canvas.drawingPolicy = .default
    canvas.tool = PKInkingTool(.pen, color: .label, width: 3)
    canvas.accessibilityIdentifier = "passageInkCanvas"
    canvas.accessibilityLabel = "Retained passage handwriting"
    canvas.addInteraction(UIPencilInteraction(delegate: mode))
    context.coordinator.picker.addObserver(canvas)
    return canvas
  }

  func updateUIView(_ canvas: PKCanvasView, context: Context) {
    context.coordinator.parent = self
    if canvas.drawing.dataRepresentation() != drawing.dataRepresentation() {
      canvas.drawing = drawing
    }
    if context.coordinator.usesEraser != mode.usesEraser {
      context.coordinator.usesEraser = mode.usesEraser
      canvas.tool =
        mode.usesEraser ? PKEraserTool(.bitmap) : PKInkingTool(.pen, color: .label, width: 3)
    }
    canvas.isDrawingEnabled = mode.isWriting
    context.coordinator.picker.setVisible(mode.showsPalette, forFirstResponder: canvas)
    if mode.showsPalette { canvas.becomeFirstResponder() }
    if context.coordinator.fixtureGeneration != fixtureGeneration {
      context.coordinator.fixtureGeneration = fixtureGeneration
      let offset = CGFloat(canvas.drawing.strokes.count * 12)
      let points = [
        CGPoint(x: 36, y: 42 + offset), CGPoint(x: 80, y: 68 + offset),
        CGPoint(x: 140, y: 40 + offset),
      ]
      let path = PKStrokePath(
        controlPoints: points.enumerated().map { index, point in
          PKStrokePoint(
            location: point, timeOffset: Double(index) * 0.05, size: CGSize(width: 3, height: 3),
            opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }, creationDate: Date(timeIntervalSince1970: 0))
      Task { @MainActor in
        canvas.drawing = PKDrawing(
          strokes: canvas.drawing.strokes + [PKStroke(ink: PKInk(.pen, color: .label), path: path)])
      }
    }
    canvas.accessibilityValue = "\(canvas.drawing.strokes.count) retained strokes"
  }

  static func dismantleUIView(_ canvas: PKCanvasView, coordinator: Coordinator) {
    coordinator.picker.removeObserver(canvas)
    canvas.delegate = nil
  }

  @MainActor final class Coordinator: NSObject, PKCanvasViewDelegate {
    var parent: PencilPassageCanvas
    let picker = PKToolPicker()
    var fixtureGeneration = 0
    var usesEraser = false
    init(_ parent: PencilPassageCanvas) { self.parent = parent }
    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
      parent.drawing = canvasView.drawing
    }
  }
}

struct EnglishScribbleTextView: UIViewRepresentable {
  @Binding var text: String
  var fixtureGeneration = 0

  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeUIView(context: Context) -> UITextView {
    let view = UITextView()
    view.delegate = context.coordinator
    view.font = .preferredFont(forTextStyle: .body)
    view.adjustsFontForContentSizeCategory = true
    view.backgroundColor = .secondarySystemBackground
    view.accessibilityIdentifier = "passageNoteText"
    view.accessibilityLabel = "English text note"
    view.autocorrectionType = .yes
    view.smartQuotesType = .yes
    return view
  }
  func updateUIView(_ view: UITextView, context: Context) {
    context.coordinator.parent = self
    if view.text != text { view.text = text }
    if context.coordinator.fixtureGeneration != fixtureGeneration {
      context.coordinator.fixtureGeneration = fixtureGeneration
      Task { @MainActor in
        view.becomeFirstResponder()
        view.insertText("Converted English passage fixture")
        context.coordinator.textViewDidChange(view)
      }
    }
  }
  @MainActor final class Coordinator: NSObject, UITextViewDelegate {
    var parent: EnglishScribbleTextView
    var fixtureGeneration = 0
    init(_ parent: EnglishScribbleTextView) { self.parent = parent }
    func textViewDidChange(_ textView: UITextView) {
      parent.text = String(textView.text.prefix(16_000))
    }
  }
}
