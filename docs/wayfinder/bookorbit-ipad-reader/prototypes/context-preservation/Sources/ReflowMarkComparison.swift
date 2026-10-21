import PencilKit
import UIKit

extension ReflowController {
  func comparisonLines() -> [CGRect] {
    guard let group = review.groups.first,
      let matches = latestPacket["groups"] as? [[String: Any]],
      let match = matches.first(where: { $0["id"] as? String == group.id }),
      let rects = match["rects"] as? [[String: Double]]
    else { return [] }
    let sorted = rects.compactMap { value -> CGRect? in
      guard let x = value["x"], let y = value["y"], let width = value["width"],
        let height = value["height"], width > 0, height > 0
      else { return nil }
      return CGRect(x: x, y: y, width: width, height: height)
    }.sorted { abs($0.midY - $1.midY) < 2 ? $0.minX < $1.minX : $0.midY < $1.midY }
    var lines: [CGRect] = []
    for rect in sorted {
      if let last = lines.last, abs(last.midY - rect.midY) < max(last.height, rect.height) * 0.4 {
        lines[lines.count - 1] = last.union(rect)
      } else {
        lines.append(rect)
      }
    }
    return lines
  }

  func performMarkComparison(_ action: String) {
    guard let group = review.groups.first, let drawing = drawings[group.id],
      !drawing.strokes.isEmpty
    else {
      status.text = "First select the sentence and draw your own mark in this walkthrough."
      return
    }
    writing = false
    updateWriting()
    let original = folder.appending(path: group.id + "-original.drawing")
    if !FileManager.default.fileExists(atPath: original.path) {
      try? drawing.dataRepresentation().write(to: original, options: .atomic)
    }
    review.markLayout =
      action == "mark-per-line"
      ? "per-line"
      : action == "mark-enclosing" ? "enclosing" : action == "mark-neat" ? "neat" : "original"
    review.layoutActions.append(action)
    let restore = action == "mark-restore"
    let font = restore ? group.font : group.font + 8
    let width = restore ? "wide" : "narrow"
    js(
      "(async()=>{await window.reflow.layout('\(width)');await window.reflow.restoreFont(\(font));})()"
    )
    applyGeometry()
    save()
  }

  func applyMarkComparison() {
    for preview in previews { preview.removeFromSuperview() }
    previews.removeAll()
    projectedGroupID = nil
    activeAvailable = false
    applying = true
    canvas.drawing = PKDrawing()
    applying = false
    canvas.isDrawingEnabled = false
    guard let group = review.groups.first, let original = drawings[group.id],
      !original.strokes.isEmpty
    else { return }
    let lines = comparisonLines()
    guard !lines.isEmpty, lines.count <= 12,
      lines.allSatisfy({ reader.bounds.insetBy(dx: -2, dy: -2).contains($0) })
    else {
      status.text =
        "The complete sentence must be on this page to compare outlines. Navigate back to it."
      return
    }
    let source = original.bounds
    guard source.width > 0, source.height > 0 else { return }
    let mode = review.markLayout ?? "original"
    let fontScale = (latestPacket["font"] as? Double ?? group.font) / group.font
    let enclosing = lines.dropFirst().reduce(lines[0]) { $0.union($1) }
    let targets = mode == "enclosing" ? [enclosing] : lines
    var strokes: [PKStroke] = []
    var pieces: [[String: Any]] = []
    for (index, line) in targets.enumerated() {
      let target: CGRect
      if scenario.markKind == "underline" {
        target = CGRect(
          x: line.minX, y: line.maxY + 2 * fontScale,
          width: line.width, height: max(source.height * fontScale, 1))
      } else {
        target = line.insetBy(dx: -4 * fontScale, dy: -3 * fontScale)
      }
      let a = target.width / source.width
      let d = target.height / source.height
      let transform = CGAffineTransform(
        a: a, b: 0, c: 0, d: d,
        tx: target.minX - source.minX * a, ty: target.minY - source.minY * d)
      if mode == "neat" {
        strokes.append(neatOutline(target, ink: original.strokes[0].ink, scale: fontScale))
      } else {
        strokes.append(contentsOf: original.transformed(using: transform).strokes)
      }
      var piece: [String: Any] = [
        "piece": index, "sourceGroup": group.id,
        "target": [
          "x": target.minX, "y": target.minY, "width": target.width, "height": target.height,
        ],
        "construction": mode == "neat"
          ? "generated rounded outline with regular thickness" : "affine copy of original strokes",
      ]
      if mode != "neat" {
        piece["transform"] = ["a": a, "d": d, "tx": transform.tx, "ty": transform.ty]
      }
      pieces.append(piece)
    }
    let display = PKDrawing(strokes: strokes)
    comparisonDrawing = display
    let image = UIImageView(
      image: display.image(from: reader.bounds, scale: traitCollection.displayScale))
    image.frame = reader.bounds
    image.isUserInteractionEnabled = false
    reader.insertSubview(image, belowSubview: canvas)
    previews.append(image)
    let boxes = UIBezierPath()
    for line in lines { boxes.append(UIBezierPath(rect: line)) }
    highlights.path = boxes.cgPath
    selected.text =
      mode == "neat"
      ? "Viewing newly drawn neat outlines on each line"
      : mode == "enclosing"
        ? "Viewing one reshaped outline around the sentence"
        : "Viewing a reshaped copy on each line"
    status.text =
      "Appearance comparison: original ink is kept. Editing these copies is a later test."
    let record: [String: Any] = [
      "mode": mode, "role": scenario.markKind ?? "",
      "assignment": "This standalone walkthrough explicitly requests only this kind of mark",
      "sourceGroup": group.id, "sourceCFI": group.cfi, "sourceHash": group.sourceHash,
      "canonicalInkHash": digest(original.dataRepresentation()), "lineCount": lines.count,
      "pieces": pieces, "derivedEditablePiecesValidated": false,
      "scope":
        mode == "neat"
        ? "New rounded native strokes using the first source ink and regular thickness; original shape and pressure are not copied"
        : "Native PencilKit stroke copies with affine reshaping; not stroke splitting or automatic role recognition"
        ,
    ]
    if let data = try? JSONSerialization.data(
      withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
    {
      try? data.write(to: folder.appending(path: "mark-comparison.json"), options: .atomic)
    }
    try? display.dataRepresentation().write(
      to: folder.appending(path: "comparison-\(mode).drawing"), options: .atomic)
  }

  func neatOutline(_ rect: CGRect, ink: PKInk, scale: Double) -> PKStroke {
    let radius = min(rect.height / 3, 10 * scale)
    let centers = [
      CGPoint(x: rect.maxX - radius, y: rect.minY + radius),
      CGPoint(x: rect.maxX - radius, y: rect.maxY - radius),
      CGPoint(x: rect.minX + radius, y: rect.maxY - radius),
      CGPoint(x: rect.minX + radius, y: rect.minY + radius),
    ]
    var points: [CGPoint] = []
    for (corner, center) in centers.enumerated() {
      for step in 0...8 {
        let angle = -.pi / 2 + Double(corner) * .pi / 2 + Double(step) / 8 * .pi / 2
        points.append(CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius))
      }
    }
    points.append(points[0])
    return PKStroke(
      ink: ink,
      path: PKStrokePath(
        controlPoints: points.enumerated().map { index, point in
          PKStrokePoint(
            location: point, timeOffset: Double(index) * 0.02,
            size: CGSize(width: 3 * scale, height: 3 * scale), opacity: 1, force: 0.7, azimuth: 0,
            altitude: .pi / 2)
        }, creationDate: Date()))
  }

  func comparisonProbePaths() -> [[CGPoint]] {
    let lines = comparisonLines()
    guard let first = lines.first else { return [] }
    let rect = lines.dropFirst().reduce(first) { $0.union($1) }
    if scenario.markKind == "underline" {
      return [
        [
          CGPoint(x: rect.minX, y: rect.maxY + 3),
          CGPoint(x: rect.midX, y: rect.maxY + 5), CGPoint(x: rect.maxX, y: rect.maxY + 3),
        ]
      ]
    }
    let outline = rect.insetBy(dx: -5, dy: -5)
    return [
      (0...48).map { index in
        let angle = CGFloat(index) / 48 * .pi * 2
        return CGPoint(
          x: outline.midX + cos(angle) * outline.width / 2,
          y: outline.midY + sin(angle) * outline.height / 2)
      }
    ]
  }

  func captureComparison(_ name: String) async {
    let ink = comparisonDrawing ?? canvas.drawing
    let image: UIImage? = await withCheckedContinuation { continuation in
      web.takeSnapshot(with: nil) { image, _ in continuation.resume(returning: image) }
    }
    guard let image else { return }
    let overlay = ink.image(from: reader.bounds, scale: 2)
    let result = UIGraphicsImageRenderer(size: reader.bounds.size).image { _ in
      image.draw(in: reader.bounds)
      overlay.draw(in: reader.bounds)
    }
    try? result.pngData()?.write(
      to: folder.appending(path: "comparison-\(name).png"), options: .atomic)
  }

  func runComparisonProbe() async {
    guard let group = review.groups.first, let original = drawings[group.id],
      !original.strokes.isEmpty
    else { return }
    let before = digest(original.dataRepresentation())
    await captureComparison("before-wrap")
    var actions = ["mark-original", "mark-per-line"]
    if scenario.markKind == "circle" {
      actions.append(contentsOf: ["mark-enclosing", "mark-neat"])
    }
    actions.append("mark-restore")
    for action in actions {
      performMarkComparison(action)
      try? await Task.sleep(for: .seconds(1))
      await captureComparison(action)
    }
    let after = digest((drawings[group.id] ?? PKDrawing()).dataRepresentation())
    let result: [String: Any] = [
      "canonicalHashBefore": before, "canonicalHashAfter": after,
      "canonicalInkUnchanged": before == after, "actions": actions,
      "triedChecksSet": review.tried.filter { $0 }.count,
      "humanAnswerPresent": review.answer != nil,
      "input": "Synthetic native mark and programmatic sentence selection; no user verdict",
    ]
    if let data = try? JSONSerialization.data(
      withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    {
      try? data.write(to: folder.appending(path: "comparison-probe.json"), options: .atomic)
    }
  }
}
