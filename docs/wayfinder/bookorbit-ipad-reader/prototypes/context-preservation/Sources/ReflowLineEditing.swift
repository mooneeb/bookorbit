import PencilKit
import UIKit

struct ReflowLineCopy: Codable {
  var id: String
  var cfi: String
  var quote: String
  var reference: ReflowRect
  var font: Double
}

extension ReflowController {
  func currentLineBindings() -> [[String: Any]] {
    guard let group = review.groups.first,
      let matches = latestPacket["groups"] as? [[String: Any]],
      let match = matches.first(where: { $0["id"] as? String == group.id }),
      match["status"] as? String == "resolved"
    else { return [] }
    return match["lines"] as? [[String: Any]] ?? []
  }

  func lineRect(_ value: [String: Any]) -> CGRect? {
    guard let rect = value["rect"] as? [String: Double], let x = rect["x"], let y = rect["y"],
      let width = rect["width"], let height = rect["height"], width > 0, height > 0
    else { return nil }
    return CGRect(x: x, y: y, width: width, height: height)
  }

  func performLocalEdit(_ action: String) {
    guard let group = review.groups.first, let source = drawings[group.id],
      !source.strokes.isEmpty
    else {
      status.text = "First select the whole sentence and draw your own mark."
      return
    }
    writing = false
    updateWriting()
    review.layoutActions.append(action)
    if action == "local-reload" {
      guard review.lineCopies != nil else {
        status.text = "First tap Wrap and prepare editable lines in step 2."
        return
      }
      var loaded: [String: PKDrawing] = [:]
      for copy in review.lineCopies ?? [] {
        guard let data = try? Data(contentsOf: folder.appending(path: copy.id + ".drawing")),
          let drawing = try? PKDrawing(data: data)
        else {
          status.text = "A saved line could not be reopened. Existing ink has been kept."
          return
        }
        loaded[copy.id] = drawing
      }
      lineDrawings = loaded
      projectedGroupID = nil
      canvas.undoManager?.removeAllActions()
      save()
      js("window.reflow.reload()")
      return
    }
    if review.lineCopies != nil {
      status.text = "Your independently edited lines are already prepared and have been kept."
      applyLineGeometry()
      return
    }
    preparingLines = true
    save()
    js(
      "(async()=>{await window.reflow.layout('narrow');await window.reflow.restoreFont(\(group.font + 8));})()"
    )
  }

  func finishPreparingLines() {
    guard let group = review.groups.first, let source = drawings[group.id],
      (latestPacket["font"] as? Double) == group.font + 8
    else { return }
    let bindings = currentLineBindings()
    guard bindings.count >= 2, bindings.count <= 12,
      bindings.compactMap({ $0["quote"] as? String }).joined() == group.quote,
      bindings.allSatisfy({ value in
        guard let rect = lineRect(value) else { return false }
        return reader.bounds.insetBy(dx: -2, dy: -2).contains(rect)
      }), source.bounds.width > 0, source.bounds.height > 0
    else {
      preparingLines = false
      status.text =
        "The whole selected sentence must wrap onto at least two visible lines. Restart this walkthrough and select only the first sentence."
      return
    }
    var copies: [ReflowLineCopy] = []
    let font = group.font + 8
    let scale = font / group.font
    do {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let original = folder.appending(path: group.id + "-original.drawing")
      if !FileManager.default.fileExists(atPath: original.path) {
        try source.dataRepresentation().write(to: original, options: .atomic)
      }
      for binding in bindings {
        guard let rect = lineRect(binding), let cfi = binding["cfi"] as? String,
          let quote = binding["quote"] as? String
        else { return }
        let target =
          scenario.markKind == "underline"
          ? CGRect(
            x: rect.minX, y: rect.maxY + 2 * scale, width: rect.width,
            height: max(source.bounds.height * scale, 1))
          : rect.insetBy(dx: -4 * scale, dy: -3 * scale)
        let a = target.width / source.bounds.width
        let d = target.height / source.bounds.height
        let drawing = source.transformed(
          using: CGAffineTransform(
            a: a, b: 0, c: 0, d: d,
            tx: target.minX - source.bounds.minX * a,
            ty: target.minY - source.bounds.minY * d))
        let copy = ReflowLineCopy(
          id: UUID().uuidString, cfi: cfi, quote: quote,
          reference: ReflowRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height),
          font: font)
        try drawing.dataRepresentation().write(
          to: folder.appending(path: copy.id + ".drawing"), options: .atomic)
        lineDrawings[copy.id] = drawing
        copies.append(copy)
      }
      review.lineCopies = copies
      review.markLayout = "local-edit"
      activeLine = 0
      projectedGroupID = nil
      preparingLines = false
      save()
    } catch {
      preparingLines = false
      status.text = "The editable line copies could not be saved: \(error.localizedDescription)"
    }
  }

  func applyLineGeometry() {
    guard let copies = review.lineCopies, !copies.isEmpty else { return }
    let bindings = currentLineBindings()
    guard bindings.count == copies.count,
      zip(copies, bindings).allSatisfy({ copy, binding in
        copy.cfi == binding["cfi"] as? String && copy.quote == binding["quote"] as? String
          && lineRect(binding) != nil
      })
    else {
      activeAvailable = false
      canvas.isDrawingEnabled = false
      status.text =
        "This local-edit check needs the same line breaks. Return the iPad to its starting orientation. Saved ink is kept; editing waits for the original line layout."
      return
    }
    for preview in previews { preview.removeFromSuperview() }
    previews.removeAll()
    comparisonDrawing = nil
    let boxes = UIBezierPath()
    var visible = false
    for (index, copy) in copies.enumerated() {
      guard let rect = lineRect(bindings[index]), let drawing = lineDrawings[copy.id] else {
        continue
      }
      let scale = (latestPacket["font"] as? Double ?? copy.font) / copy.font
      let transform = CGAffineTransform(
        a: scale, b: 0, c: 0, d: scale,
        tx: rect.minX - copy.reference.x * scale, ty: rect.minY - copy.reference.y * scale)
      let display = transform == .identity ? drawing : drawing.transformed(using: transform)
      if index == activeLine {
        visible = reader.bounds.contains(rect)
        boxes.append(UIBezierPath(rect: rect))
        if projectedGroupID != copy.id || projection != transform {
          applying = true
          canvas.drawing = display
          applying = false
          projectedGroupID = copy.id
          projection = transform
          canvas.undoManager?.removeAllActions()
        }
        selected.text = "Editing line \(index + 1) of \(copies.count): \(copy.quote)"
      } else if !display.strokes.isEmpty {
        let image = UIImageView(
          image: display.image(from: reader.bounds, scale: traitCollection.displayScale))
        image.frame = reader.bounds
        image.isUserInteractionEnabled = false
        reader.insertSubview(image, belowSubview: canvas)
        previews.append(image)
      }
    }
    activeAvailable = visible
    canvas.isDrawingEnabled = writing && visible
    highlights.path = boxes.cgPath
    status.text =
      "Only the selected line is editable. Other lines stay visible. Undo starts fresh when you switch lines or reload. Keep this orientation for this check."
    saveLineEvidence()
  }

  func switchLine() {
    guard let copies = review.lineCopies, !copies.isEmpty else {
      status.text = "First tap Wrap and prepare editable lines in step 2."
      return
    }
    writing = false
    updateWriting()
    save()
    activeLine = (activeLine + 1) % copies.count
    projectedGroupID = nil
    applyLineGeometry()
  }

  func saveLineDrawing() {
    guard !applying, activeAvailable, let copies = review.lineCopies,
      copies.indices.contains(activeLine), projectedGroupID == copies[activeLine].id
    else { return }
    let copy = copies[activeLine]
    let drawing =
      projection == .identity
      ? canvas.drawing : canvas.drawing.transformed(using: projection.inverted())
    do {
      try drawing.dataRepresentation().write(
        to: folder.appending(path: copy.id + ".drawing"), options: .atomic)
      lineDrawings[copy.id] = drawing
      save()
      saveLineEvidence()
    } catch {
      status.text = "This line's edit could not be saved: \(error.localizedDescription)"
    }
  }

  func saveLineEvidence() {
    guard let copies = review.lineCopies else { return }
    let record: [String: Any] = [
      "activeLine": activeLine + 1,
      "pieces": copies.map { copy -> [String: Any] in
        [
          "id": copy.id, "cfi": copy.cfi, "quote": copy.quote,
          "inkHash": lineDrawings[copy.id].map { digest($0.dataRepresentation()) } ?? "missing",
          "referenceFrame": [
            "x": copy.reference.x, "y": copy.reference.y,
            "width": copy.reference.width, "height": copy.reference.height,
          ],
        ]
      },
      "sourceInkHashes": drawings.mapValues { digest($0.dataRepresentation()) },
      "framePolicy": "Fixed text-line reference frames, never refit to edited drawing bounds",
      "identityPolicy": "Separate native drawing and exact line range CFI/quote per copied mark",
      "scope":
        "Same-line-layout local editing; subsequent reflow of edited pieces remains unvalidated",
      "undoPolicy": "Native Undo per active line; switching lines or reloading clears Undo history",
    ]
    if let data = try? JSONSerialization.data(
      withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
    {
      try? data.write(to: folder.appending(path: "local-edit-state.json"), options: .atomic)
    }
  }

  func captureLocalEdit(_ name: String) async {
    let image: UIImage? = await withCheckedContinuation { continuation in
      web.takeSnapshot(with: nil) { image, _ in continuation.resume(returning: image) }
    }
    guard let image, let copies = review.lineCopies else { return }
    let ink = PKDrawing(strokes: copies.flatMap { lineDrawings[$0.id]?.strokes ?? [] })
    let result = UIGraphicsImageRenderer(size: reader.bounds.size).image { _ in
      image.draw(in: reader.bounds)
      ink.image(from: reader.bounds, scale: 2).draw(in: reader.bounds)
    }
    try? result.pngData()?.write(to: folder.appending(path: "local-\(name).png"), options: .atomic)
  }

  func runLocalEditProbe() async {
    performLocalEdit("local-prepare")
    try? await Task.sleep(for: .seconds(2))
    guard let copies = review.lineCopies, copies.count >= 2,
      let original = lineDrawings[copies[0].id], let source = review.groups.first
    else { return }
    let sourceBefore = digest((drawings[source.id] ?? PKDrawing()).dataRepresentation())
    let otherBefore = try? Data(contentsOf: folder.appending(path: copies[1].id + ".drawing"))
    await captureLocalEdit("before-edit")
    // The probe supplies an edit through the real delegate; physical eraser behavior is a human gate.
    let shortened = PKDrawing(
      strokes: original.strokes.map { stroke in
        let points = Array(stroke.path).prefix(max(2, stroke.path.count / 2))
        return PKStroke(
          ink: stroke.ink,
          path: PKStrokePath(controlPoints: points, creationDate: stroke.path.creationDate),
          transform: stroke.transform, mask: stroke.mask)
      })
    applying = true
    canvas.drawing = shortened
    applying = false
    saveLineDrawing()
    let edited = try? Data(contentsOf: folder.appending(path: copies[0].id + ".drawing"))
    await captureLocalEdit("after-edit")
    switchLine()
    let otherAfter = try? Data(contentsOf: folder.appending(path: copies[1].id + ".drawing"))
    let otherDisplayMatches =
      pixelHash(canvas.drawing)
      == pixelHash((lineDrawings[copies[1].id] ?? PKDrawing()).transformed(using: projection))
    performLocalEdit("local-reload")
    try? await Task.sleep(for: .seconds(1))
    switchLine()
    let afterReload = try? Data(contentsOf: folder.appending(path: copies[0].id + ".drawing"))
    let editedDisplayMatches =
      pixelHash(canvas.drawing)
      == pixelHash((lineDrawings[copies[0].id] ?? PKDrawing()).transformed(using: projection))
    let record: [String: Any] = [
      "pieceCount": copies.count,
      "firstLineChanged": edited != nil && edited != original.dataRepresentation(),
      "otherLineUnchanged": otherBefore != nil && otherBefore == otherAfter,
      "otherLineDisplayedCorrectlyAfterSwitch": otherDisplayMatches,
      "editedLinePreservedAfterSwitchAndReload": edited != nil && edited == afterReload,
      "editedLineDisplayedCorrectlyAfterReload": editedDisplayMatches,
      "sourceInkUnchanged": sourceBefore
        == digest((drawings[source.id] ?? PKDrawing()).dataRepresentation()),
      "triedChecksSet": review.tried.filter { $0 }.count,
      "humanAnswerPresent": review.answer != nil,
      "input":
        "Synthetic native marks and delegate edit, not physical Pencil eraser/Undo validation",
    ]
    if let data = try? JSONSerialization.data(
      withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
    {
      try? data.write(to: folder.appending(path: "local-edit-probe.json"), options: .atomic)
    }
  }

  func pixelHash(_ drawing: PKDrawing) -> String {
    digest(drawing.image(from: reader.bounds, scale: 1).pngData() ?? Data())
  }
}
