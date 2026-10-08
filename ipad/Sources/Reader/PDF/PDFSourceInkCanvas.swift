import PDFKit
import PencilKit
import UIKit

@MainActor
final class PDFSourceInkCanvas: UIView, PKCanvasViewDelegate, UIGestureRecognizerDelegate {
  let draft = PKCanvasView()
  private let selection = CAShapeLayer()
  private let lasso = CAShapeLayer()
  private var images: [String: UIImageView] = [:]
  private var drawings: [String: PKDrawing] = [:]
  private var payloads: [String: NativeAnnotationDrawing] = [:]
  private(set) var visibleAnnotationIDs: Set<Int> = []
  private var editor: PDFSourceInkEditor?
  private var pageIndex = 0
  private var isApplying = false
  private var gestureStart = CGPoint.zero
  private var lassoPoints: [CGPoint] = []
  private var preview: PKDrawing?
  private var gestureIdentity: String?
  private var gestureVersion: Int?
  private var pencilInteraction: UIPencilInteraction?
  private let picker = PKToolPicker()
  private var previousEraser: Bool?
  private var previousInk: PKTool = PKInkingTool(.pen, color: .black, width: 3)
  private lazy var tap = UITapGestureRecognizer(target: self, action: #selector(selectItem))
  private lazy var drag = UIPanGestureRecognizer(target: self, action: #selector(dragItem))
  private lazy var resize = UIPinchGestureRecognizer(target: self, action: #selector(resizeItem))

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    clipsToBounds = true
    draft.backgroundColor = .clear
    draft.isOpaque = false
    draft.isScrollEnabled = false
    draft.drawingPolicy = .pencilOnly
    draft.tool = PKInkingTool(.pen, color: .black, width: 3)
    draft.delegate = self
    picker.addObserver(draft)
    addSubview(draft)
    for shape in [selection, lasso] {
      shape.fillColor = UIColor.clear.cgColor
      shape.strokeColor = tintColor.cgColor
      shape.lineWidth = 1.5
      shape.lineDashPattern = [6, 3]
      layer.addSublayer(shape)
    }
    let recognizers: [UIGestureRecognizer] = [tap, drag, resize]
    for recognizer in recognizers {
      recognizer.delegate = self
      addGestureRecognizer(recognizer)
    }
    tap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
    drag.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
    tap.require(toFail: drag)
    accessibilityIdentifier = "pdfSourceInkCanvas"
  }

  required init?(coder: NSCoder) { nil }

  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    if editor?.tool == .draw, editor?.isDrawingStroke != true,
      let touches = event?.allTouches, touches.contains(where: { $0.type == .direct }),
      !touches.contains(where: { $0.type == .pencil })
    {
      return nil
    }
    return super.hitTest(point, with: event)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    draft.frame = bounds
    selection.frame = bounds
    lasso.frame = bounds
  }

  func update(editor: PDFSourceInkEditor, pageIndex: Int, size: CGSize) {
    self.editor = editor
    self.pageIndex = pageIndex
    if editor.currentPage == pageIndex {
      editor.fixtureLassoInput = { [weak self, weak editor] in
        guard let self, let editor, editor.currentPage == self.pageIndex else { return }
        self.feedFixtureLasso()
      }
    }
    if pencilInteraction == nil {
      let interaction = UIPencilInteraction(delegate: editor.mode)
      addInteraction(interaction)
      pencilInteraction = interaction
    }
    bounds = CGRect(origin: .zero, size: size)
    let groups = editor.groups(on: pageIndex)
    visibleAnnotationIDs = []
    let identities = Set(groups.map { editor.identity($0) })
    for key in Array(images.keys) where !identities.contains(key) {
      images.removeValue(forKey: key)?.removeFromSuperview()
      drawings.removeValue(forKey: key)
      payloads.removeValue(forKey: key)
    }
    for item in groups {
      let key = editor.identity(item)
      guard let payload = item.drawing else { continue }
      let image = images[key] ?? UIImageView()
      if images[key] == nil {
        image.isUserInteractionEnabled = false
        image.isAccessibilityElement = true
        image.accessibilityIdentifier = "pdfInkItem\(key)"
        insertSubview(image, belowSubview: draft)
        images[key] = image
      }
      image.accessibilityLabel = "Ink item, page \(pageIndex + 1)"
      if payloads[key] != payload, let drawing = PDFSourceInkDrawing.decode(payload) {
        render(drawing, in: image)
        drawings[key] = drawing
        payloads[key] = payload
      }
      if drawings[key] != nil { visibleAnnotationIDs.insert(item.id) }
    }
    isApplying = true
    let pending = editor.draftPage == pageIndex ? editor.draft : PKDrawing()
    if draft.drawing.dataRepresentation() != pending.dataRepresentation() {
      draft.drawing = pending
    }
    isApplying = false
    let drawing = editor.mode.isWriting && editor.tool == .draw && editor.canEdit
    draft.isUserInteractionEnabled = drawing
    if previousEraser != editor.mode.usesEraser {
      if editor.mode.usesEraser {
        previousInk = draft.tool
        draft.tool = PKEraserTool(.bitmap)
      } else {
        draft.tool = previousInk
      }
      previousEraser = editor.mode.usesEraser
    }
    picker.setVisible(editor.mode.showsPalette && drawing, forFirstResponder: draft)
    if editor.mode.showsPalette && drawing { draft.becomeFirstResponder() }
    tap.isEnabled = editor.mode.isWriting && editor.tool == .select && editor.canEdit
    drag.isEnabled = editor.mode.isWriting && editor.tool != .draw && editor.canEdit
    resize.isEnabled = editor.mode.isWriting && editor.tool == .select && editor.canEdit
    isUserInteractionEnabled = editor.mode.isWriting && editor.canEdit
    updateSelection()
    if let fixtureGeneration = editor.consumeFixtureGeneration(on: pageIndex) {
      let fixture = PDFSourceInkDrawing.fixture().transformed(
        using:
          CGAffineTransform(translationX: 0, y: CGFloat(max(0, fixtureGeneration - 1) * 32)))
      canvasViewDidBeginUsingTool(draft)
      draft.drawing = PKDrawing(strokes: draft.drawing.strokes + fixture.strokes)
      canvasViewDrawingDidChange(draft)
      canvasViewDidEndUsingTool(draft)
    }
    setNeedsLayout()
  }

  func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
    guard !isApplying, let editor else { return }
    editor.preview(canvasView.drawing, page: pageIndex)
  }

  func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
    editor?.beginStroke()
  }

  func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
    editor?.endStroke()
  }

  private func render(_ drawing: PKDrawing, in image: UIImageView) {
    let rect = drawing.bounds.insetBy(dx: -2, dy: -2)
    guard !rect.isNull, rect.width > 0, rect.height > 0 else { return }
    image.frame = rect
    image.image = drawing.image(from: rect, scale: min(3, max(1, traitCollection.displayScale)))
  }

  private func updateSelection() {
    guard let editor, let key = editor.selectedIdentity, let drawing = preview ?? drawings[key]
    else {
      selection.path = nil
      return
    }
    let selected = editor.selectedDrawing(in: drawing)
    guard !selected.strokes.isEmpty else {
      selection.path = nil
      return
    }
    selection.path = UIBezierPath(rect: selected.bounds.insetBy(dx: -5, dy: -5)).cgPath
    selection.strokeColor = tintColor.cgColor
  }

  @objc private func selectItem(_ sender: UITapGestureRecognizer) {
    let point = sender.location(in: self)
    let match = drawings.keys.sorted().last { key in
      drawings[key]?.bounds.insetBy(dx: -8, dy: -8).contains(point) == true
    }
    editor?.select(identity: match)
    updateSelection()
  }

  @objc private func dragItem(_ sender: UIPanGestureRecognizer) {
    guard let editor else { return }
    let point = sender.location(in: self)
    if editor.tool == .lasso {
      handleLasso(sender.state, point: point)
      return
    }
    guard let key = editor.selectedIdentity, let drawing = drawings[key],
      !editor.selectedStrokeIndices(in: drawing).isEmpty
    else {
      if [.ended, .cancelled, .failed].contains(sender.state) { editor.endSelectionTransform() }
      return
    }
    switch sender.state {
    case .began:
      editor.beginSelectionTransform()
      gestureStart = point
      gestureIdentity = editor.selectedIdentity
      gestureVersion = editor.selected?.version
      preview = drawing
    case .changed:
      preview = editor.transformingSelectedStrokes(
        in: drawing,
        using:
          CGAffineTransform(translationX: point.x - gestureStart.x, y: point.y - gestureStart.y))
      if let preview, let image = images[key] { render(preview, in: image) }
      updateSelection()
    case .ended:
      if let preview {
        editor.replaceSelected(
          with: preview, expectedIdentity: gestureIdentity, expectedVersion: gestureVersion)
      }
      preview = nil
      editor.endSelectionTransform()
      gestureIdentity = nil
      gestureVersion = nil
      if let image = images[key] { render(drawing, in: image) }
      updateSelection()
    case .cancelled, .failed:
      preview = nil
      editor.endSelectionTransform()
      gestureIdentity = nil
      gestureVersion = nil
      if let image = images[key] { render(drawing, in: image) }
      updateSelection()
    default: break
    }
  }

  private func handleLasso(_ state: UIGestureRecognizer.State, point: CGPoint) {
    switch state {
    case .began:
      editor?.beginSelectionTransform()
      lassoPoints = [point]
    case .changed:
      guard lassoPoints.count < 2_000 else { return }
      lassoPoints.append(point)
      let path = UIBezierPath()
      if let first = lassoPoints.first { path.move(to: first) }
      for value in lassoPoints.dropFirst() { path.addLine(to: value) }
      lasso.path = path.cgPath
    case .ended:
      lassoPoints.append(point)
      let path = UIBezierPath()
      if let first = lassoPoints.first { path.move(to: first) }
      for value in lassoPoints.dropFirst() { path.addLine(to: value) }
      path.close()
      var matches: [String: Set<Int>] = [:]
      for key in drawings.keys.sorted() {
        guard let drawing = drawings[key] else { continue }
        let indices = Set(
          drawing.strokes.indices.filter { index in
            let stroke = drawing.strokes[index]
            return stroke.path.interpolatedPoints(by: .distance(2)).prefix(10_001).contains {
              path.contains($0.location.applying(stroke.transform))
            }
          })
        if !indices.isEmpty { matches[key] = indices }
      }
      let match = matches.keys.sorted().last
      editor?.select(identity: match, strokeIndices: match.flatMap { matches[$0] })
      editor?.endSelectionTransform()
      lasso.path = nil
      lassoPoints = []
      updateSelection()
    case .cancelled, .failed:
      editor?.endSelectionTransform()
      lasso.path = nil
      lassoPoints = []
    default: break
    }
  }

  private func feedFixtureLasso() {
    let polygon = [
      CGPoint(x: 60, y: 180), CGPoint(x: 210, y: 180),
      CGPoint(x: 210, y: 250), CGPoint(x: 60, y: 250), CGPoint(x: 60, y: 180),
    ]
    guard let first = polygon.first, let last = polygon.last else { return }
    handleLasso(.began, point: first)
    for point in polygon.dropFirst().dropLast() { handleLasso(.changed, point: point) }
    handleLasso(.ended, point: last)
  }

  @objc private func resizeItem(_ sender: UIPinchGestureRecognizer) {
    guard let editor else { return }
    guard let key = editor.selectedIdentity, let drawing = drawings[key] else {
      if [.ended, .cancelled, .failed].contains(sender.state) { editor.endSelectionTransform() }
      return
    }
    let bounds = editor.selectedDrawing(in: drawing).bounds
    guard !bounds.isNull else { return }
    let center = CGPoint(x: bounds.midX, y: bounds.midY)
    let scale = min(4, max(0.25, sender.scale))
    let transform = CGAffineTransform(translationX: -center.x, y: -center.y)
      .concatenating(CGAffineTransform(scaleX: scale, y: scale))
      .concatenating(CGAffineTransform(translationX: center.x, y: center.y))
    switch sender.state {
    case .began, .changed:
      if sender.state == .began {
        editor.beginSelectionTransform()
        gestureIdentity = editor.selectedIdentity
        gestureVersion = editor.selected?.version
      }
      preview = editor.transformingSelectedStrokes(in: drawing, using: transform)
      if let preview, let image = images[key] { render(preview, in: image) }
      updateSelection()
    case .ended:
      editor.replaceSelected(
        with: editor.transformingSelectedStrokes(in: drawing, using: transform),
        expectedIdentity: gestureIdentity, expectedVersion: gestureVersion)
      preview = nil
      editor.endSelectionTransform()
      gestureIdentity = nil
      gestureVersion = nil
      if let image = images[key] { render(drawing, in: image) }
      updateSelection()
    case .cancelled, .failed:
      preview = nil
      editor.endSelectionTransform()
      gestureIdentity = nil
      gestureVersion = nil
      if let image = images[key] { render(drawing, in: image) }
      updateSelection()
    default: break
    }
  }

  override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
    guard let editor else { return false }
    if gestureRecognizer === drag && editor.tool == .lasso { return true }
    return gestureRecognizer === tap || editor.selectedIdentity != nil
  }
}
