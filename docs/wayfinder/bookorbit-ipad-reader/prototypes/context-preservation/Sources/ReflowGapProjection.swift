import PencilKit
import UIKit

struct ReflowGapCell: Codable, Equatable {
  var cfi: String
  var quote: String
  var rect: ReflowRect
  var clip: ReflowRect
  var collapsed: Bool?
}

struct ReflowGapSnapshot: Codable {
  var file: String
  var font: Double
  var cells: [ReflowGapCell]
}

extension ReflowController {
  var gapStepRequirement: String? {
    guard scenario.gapReflow else { return nil }
    switch review.step {
    case 1 where review.lineCopies == nil:
      return
        "Tap Prepare the wrapped underline first. Continue becomes available after the sentence wraps and the editable lines appear."
    case 2 where review.gapSnapshot == nil || review.lastFont != 24:
      return
        "Tap Widen the text and follow the gap. Wait for the wider text before checking this step."
    case 3 where review.lastFont != 40:
      return
        "Tap Make text larger and follow the gap. Wait for the larger text before checking this step."
    case 5 where !review.layoutActions.contains("gap-reload"):
      return "Tap Reload the edited underline before checking the saved gap."
    default:
      return nil
    }
  }

  func currentGapCells() -> [ReflowGapCell] {
    guard let group = review.groups.first,
      let matches = latestPacket["groups"] as? [[String: Any]],
      let match = matches.first(where: { $0["id"] as? String == group.id }),
      match["status"] as? String == "resolved",
      let characters = match["characters"] as? [[String: Any]]
    else { return [] }
    let lines = currentLineBindings().compactMap { lineRect($0) }
    let font = latestPacket["font"] as? Double ?? 24
    return characters.compactMap { value in
      guard let cfi = value["cfi"] as? String, let quote = value["quote"] as? String,
        let rect = lineRect(value),
        let line = lines.firstIndex(where: { abs($0.midY - rect.midY) < rect.height * 0.4 })
      else { return nil }
      let bottom = line + 1 < lines.count ? lines[line + 1].minY - 2 : rect.maxY + font * 0.9
      return ReflowGapCell(
        cfi: cfi, quote: quote,
        rect: ReflowRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height),
        clip: ReflowRect(
          x: rect.minX, y: lines[line].minY - 2,
          width: rect.width, height: bottom - lines[line].minY + 2),
        collapsed: value["collapsed"] as? Bool)
    }
  }

  func performGapAction(_ action: String) {
    writing = false
    updateWriting()
    if review.gapSnapshot == nil {
      guard let copies = review.lineCopies, !copies.isEmpty,
        !currentGapCells().isEmpty
      else {
        status.text = "First prepare the wrapped underline and erase below useful in step 2."
        return
      }
      let snapshot = ReflowGapSnapshot(
        file: "gap-current.drawing",
        font: latestPacket["font"] as? Double ?? 32, cells: currentGapCells())
      let drawing = PKDrawing(strokes: copies.flatMap { lineDrawings[$0.id]?.strokes ?? [] })
      do {
        let data = drawing.dataRepresentation()
        try data.write(to: folder.appending(path: snapshot.file), options: .atomic)
        try data.write(to: folder.appending(path: "gap-authored.drawing"), options: .atomic)
        try JSONEncoder().encode(snapshot).write(
          to: folder.appending(path: "gap-authored-binding.json"), options: .atomic)
        gapDrawing = drawing
        review.gapSnapshot = snapshot
        review.markLayout = "gap-reflow"
        gapDisplayedCells = []
      } catch {
        status.text = "The edited underline could not be saved: \(error.localizedDescription)"
        return
      }
    }
    review.layoutActions.append(action)
    save()
    if action == "gap-reload", let snapshot = review.gapSnapshot {
      guard let data = try? Data(contentsOf: folder.appending(path: snapshot.file)),
        let drawing = try? PKDrawing(data: data)
      else {
        status.text = "The saved underline could not be reopened. Existing ink is kept."
        return
      }
      gapDrawing = drawing
      gapDisplayedCells = []
      gapAssignedData = nil
      projectedGroupID = nil
      canvas.undoManager?.removeAllActions()
      js("window.reflow.reload()")
    } else {
      let font = action == "gap-large" ? 40 : 24
      js(
        "(async()=>{await window.reflow.layout('wide');await window.reflow.restoreFont(\(font));})()"
      )
    }
  }

  func projectedGap(
    _ drawing: PKDrawing, from snapshot: ReflowGapSnapshot,
    to targets: [ReflowGapCell], font: Double
  ) -> PKDrawing {
    if snapshot.cells == targets && snapshot.font == font { return drawing }
    let resolved = Dictionary(uniqueKeysWithValues: targets.map { ($0.cfi, $0) })
    var pieces: [PKStroke] = []
    for cell in snapshot.cells {
      guard let target = resolved[cell.cfi], cell.quote == target.quote,
        target.collapsed != true
      else { continue }
      let scale = font / snapshot.font
      let a = target.rect.width / cell.rect.width
      let transform = CGAffineTransform(
        a: a, b: 0, c: 0, d: scale,
        tx: target.rect.x - cell.rect.x * a,
        ty: target.rect.y + target.rect.height - (cell.rect.y + cell.rect.height) * scale)
      for source in drawing.strokes where source.renderBounds.intersects(cell.clip.cg) {
        let clip = UIBezierPath(rect: cell.clip.cg)
        clip.apply(source.transform.inverted())
        let mask: CGPath
        if let existing = source.mask {
          let normalized = existing.cgPath.normalized(
            using: existing.usesEvenOddFillRule ? .evenOdd : .winding)
          mask = normalized.intersection(clip.cgPath)
        } else {
          mask = clip.cgPath
        }
        guard !mask.isEmpty else { continue }
        var piece = source
        piece.mask = UIBezierPath(cgPath: mask)
        piece.transform = source.transform.concatenating(transform)
        if !piece.renderBounds.isEmpty { pieces.append(piece) }
      }
    }
    return PKDrawing(strokes: pieces)
  }

  func applyGapGeometry() {
    guard let snapshot = review.gapSnapshot else { return }
    let targets = currentGapCells()
    let currentCFIs = Set(targets.map(\.cfi))
    guard !targets.isEmpty, targets.count <= 160,
      targets.allSatisfy({ reader.bounds.insetBy(dx: -2, dy: -2).contains($0.rect.cg) }),
      snapshot.cells.allSatisfy({
        $0.quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          || currentCFIs.contains($0.cfi)
      })
    else {
      activeAvailable = false
      canvas.isDrawingEnabled = false
      status.text =
        "The complete selected sentence must be on this page. Return to it to inspect or edit the underline."
      return
    }
    let font = latestPacket["font"] as? Double ?? snapshot.font
    if gapDisplayedCells != targets || gapDisplayedFont != font || projectedGroupID != "gap-canvas"
    {
      let started = CFAbsoluteTimeGetCurrent()
      let display = projectedGap(gapDrawing, from: snapshot, to: targets, font: font)
      for preview in previews { preview.removeFromSuperview() }
      previews.removeAll()
      comparisonDrawing = nil
      applying = true
      canvas.drawing = display
      gapAssignedData = canvas.drawing.dataRepresentation()
      applying = false
      gapDisplayedCells = targets
      gapDisplayedFont = font
      projectedGroupID = "gap-canvas"
      canvas.undoManager?.removeAllActions()
      let record: [String: Any] = [
        "sourceFont": snapshot.font, "targetFont": font,
        "sourceCells": snapshot.cells.count, "targetCells": targets.count,
        "sourceStrokes": gapDrawing.strokes.count, "displayStrokes": display.strokes.count,
        "sourceInkHash": digest(gapDrawing.dataRepresentation()),
        "displayInkHash": digest(display.dataRepresentation()),
        "projectionMilliseconds": (CFAbsoluteTimeGetCurrent() - started) * 1000,
        "method":
          "Actual character CFIs and geometry; native masks intersect glyph-column clips before stroke transforms",
        "scope":
          "Explicit underline role, current sample, complete range on page. No circle reconstruction or general handwriting guarantee.",
      ]
      if let data = try? JSONSerialization.data(
        withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
      {
        try? data.write(to: folder.appending(path: "gap-projection.json"), options: .atomic)
      }
      try? display.dataRepresentation().write(
        to: folder.appending(path: "gap-displayed.drawing"), options: .atomic)
    }
    activeAvailable = true
    canvas.isDrawingEnabled = writing
    let path = UIBezierPath()
    for cell in targets where !cell.quote.trimmingCharacters(in: .whitespaces).isEmpty {
      path.append(UIBezierPath(rect: cell.rect.cg))
    }
    highlights.path = path.cgPath
    selected.text =
      "The whole displayed underline is editable. Its pieces follow the selected words."
    status.text =
      "Check the actual gap below useful and any extra gaps where old lines join. A layout change or reload starts a fresh Undo history."
  }

  func saveGapDrawing() {
    guard !applying, activeAvailable, projectedGroupID == "gap-canvas",
      !gapDisplayedCells.isEmpty
    else { return }
    let data = canvas.drawing.dataRepresentation()
    guard data != gapAssignedData else { return }
    let snapshot = ReflowGapSnapshot(
      file: "gap-current.drawing", font: gapDisplayedFont,
      cells: gapDisplayedCells)
    do {
      try data.write(to: folder.appending(path: snapshot.file), options: .atomic)
      gapDrawing = canvas.drawing
      review.gapSnapshot = snapshot
      gapAssignedData = data
      save()
    } catch { status.text = "The underline edit could not be saved: \(error.localizedDescription)" }
  }

  func usefulCells(_ cells: [ReflowGapCell]) -> [ReflowGapCell] {
    guard cells.count >= 6 else { return [] }
    for index in 0...(cells.count - 6) {
      let word = Array(cells[index..<(index + 6)])
      if word.map(\.quote).joined() == "useful" { return word }
    }
    return []
  }

  func inkPixelCount(_ drawing: PKDrawing, rect: CGRect) -> Int {
    let image = drawing.image(from: rect, scale: 3)
    guard let cg = image.cgImage else { return 0 }
    let width = cg.width
    let height = cg.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    return pixels.withUnsafeMutableBytes { buffer in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: width, height: height,
          bitsPerComponent: 8, bytesPerRow: width * 4,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return 0 }
      context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
      return stride(from: 3, to: buffer.count, by: 4).filter { buffer[$0] > 20 }.count
    }
  }

  func runGapProbe() async {
    performLocalEdit("local-prepare")
    try? await Task.sleep(for: .seconds(2))
    guard let copies = review.lineCopies, let first = copies.first,
      let original = lineDrawings[first.id], !original.strokes.isEmpty
    else { return }
    let cells = currentGapCells()
    let preparedViewport = latestPacket["viewport"] as? [String: Any] ?? [:]
    let preparedLineCount = copies.count
    let word = usefulCells(cells)
    guard let owner = word.dropFirst(2).first else { return }
    let gap = CGRect(
      x: owner.rect.x + owner.rect.width * 0.15,
      y: original.bounds.minY - 4, width: max(owner.rect.width * 0.7, 5),
      height: original.bounds.height + 8)
    let unmasked = PKDrawing(strokes: copies.flatMap { lineDrawings[$0.id]?.strokes ?? [] })
    let changed = PKDrawing(
      strokes: original.strokes.map { source in
        let bounds = UIBezierPath(rect: source.renderBounds.insetBy(dx: -8, dy: -8))
        bounds.apply(source.transform.inverted())
        let cut = UIBezierPath(rect: gap)
        cut.apply(source.transform.inverted())
        var result = source
        result.mask = UIBezierPath(cgPath: bounds.cgPath.subtracting(cut.cgPath))
        return result
      })
    applying = true
    canvas.drawing = changed
    applying = false
    saveLineDrawing()
    let originalSource = review.groups.first.flatMap { drawings[$0.id] }.map {
      digest($0.dataRepresentation())
    }
    performGapAction("gap-wide")
    try? await Task.sleep(for: .seconds(2))
    guard let authored = review.gapSnapshot else { return }
    var outcomes: [[String: Any]] = []
    for action in ["gap-wide", "gap-large"] {
      if action == "gap-large" {
        performGapAction(action)
        try? await Task.sleep(for: .seconds(2))
      }
      let targets = currentGapCells()
      guard let target = targets.first(where: { $0.cfi == owner.cfi }) else { return }
      let font = latestPacket["font"] as? Double ?? authored.font
      let a = target.rect.width / owner.rect.width
      let d = font / authored.font
      let expectedGap = CGRect(
        x: target.rect.x + (gap.minX - owner.rect.x) * a,
        y: target.rect.y + target.rect.height + (gap.minY - owner.rect.y - owner.rect.height) * d,
        width: gap.width * a, height: gap.height * d)
      let reference = projectedGap(unmasked, from: authored, to: targets, font: font)
      let referencePixels = inkPixelCount(reference, rect: expectedGap)
      let editedPixels = inkPixelCount(canvas.drawing, rect: expectedGap)
      outcomes.append([
        "layout": action, "font": font,
        "gapOwnerCFI": owner.cfi, "gapOwnerCharacter": owner.quote,
        "gapReferenceInkPixels": referencePixels, "gapEditedInkPixels": editedPixels,
        "gapVisibleAtExpectedCharacter": referencePixels > 0 && editedPixels < referencePixels / 3,
        "displayStrokes": canvas.drawing.strokes.count,
      ])
      await captureComparison(action)
    }
    let beforeReload = canvas.drawing
    applying = true
    canvas.drawing = PKDrawing(
      strokes: beforeReload.strokes + [
        PKStroke(
          ink: PKInk(.pen, color: .black),
          path: PKStrokePath(
            controlPoints: [
              PKStrokePoint(
                location: CGPoint(x: owner.rect.x, y: 300),
                timeOffset: 0, size: CGSize(width: 3, height: 3), opacity: 1, force: 0.7,
                azimuth: 0, altitude: .pi / 2),
              PKStrokePoint(
                location: CGPoint(x: owner.rect.x + 5, y: 300), timeOffset: 0.1,
                size: CGSize(width: 3, height: 3), opacity: 1, force: 0.7, azimuth: 0,
                altitude: .pi / 2),
            ], creationDate: Date()))
      ])
    applying = false
    saveGapDrawing()
    let saved = try? Data(contentsOf: folder.appending(path: "gap-current.drawing"))
    let visible = pixelHash(canvas.drawing)
    performGapAction("gap-reload")
    try? await Task.sleep(for: .seconds(1))
    let reloaded = try? Data(contentsOf: folder.appending(path: "gap-current.drawing"))
    let record: [String: Any] = [
      "preparedViewport": preparedViewport,
      "preparedLineCount": preparedLineCount,
      "layouts": outcomes,
      "newNativeEditSavedAndReopened": saved != nil && saved == reloaded
        && visible == pixelHash(canvas.drawing),
      "originalWholeSentenceInkUnchanged": originalSource
        == review.groups.first.flatMap { drawings[$0.id] }.map { digest($0.dataRepresentation()) },
      "triedChecksSet": review.tried.filter { $0 }.count,
      "humanAnswerPresent": review.answer != nil,
      "input":
        "Programmatic sentence selection, synthetic native underline/mask and delegate edit. Not physical erasing or Undo acceptance.",
    ]
    if let data = try? JSONSerialization.data(
      withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
    {
      try? data.write(to: folder.appending(path: "gap-probe.json"), options: .atomic)
    }
  }
}
