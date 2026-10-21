import PencilKit
import UIKit
import WebKit

struct ReflowRect: Codable {
  var x: Double
  var y: Double
  var width: Double
  var height: Double
  var cg: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

struct ReflowInkGroup: Codable {
  var id: String
  var cfi: String
  var quote: String
  var sourceHash: String
  var prefix: String
  var suffix: String
  var font: Double
  var origin: ReflowRect
  var association = "Tester explicitly selected the words and started this ink group"
  var placement =
    "Whole editable drawing uniformly scales with font size and follows the first range fragment"
}

struct ReflowReview: Codable {
  var groups: [ReflowInkGroup] = []
  var step = 0
  var tried: [Bool]
  var answer: String?
  var feedback = ""
  var layoutActions: [String] = []
  var sourceHash = ""
  var lastFont = 24.0
  var question: String?
  var localUnsentMarker = "Saved locally; not sent to a server"
}

@MainActor
final class ReflowHomeController: UIViewController {
  static let root = ScratchStore.root.appending(path: "reflow-walkthroughs")
  var scenarioButtons: [UIButton] = []
  let summary = UILabel()

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    refreshSummary()
  }
  func refreshSummary() {
    var reviewed = 0
    for (index, scenario) in ReflowScenario.all.enumerated() {
      let path = Self.root.appending(path: scenario.id).appending(path: "review.json")
      let saved = (try? Data(contentsOf: path)).flatMap {
        try? JSONDecoder().decode(ReflowReview.self, from: $0)
      }
      if saved?.answer != nil { reviewed += 1 }
      if scenarioButtons.indices.contains(index) {
        scenarioButtons[index].configuration?.subtitle =
          saved?.answer == nil ? "Not reviewed" : "Answer saved: \(saved!.answer!)"
      }
    }
    summary.text =
      "\(reviewed) of \(ReflowScenario.all.count) walkthroughs reviewed. A reported problem counts as reviewed, never as a pass."
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    let stack = UIStackView()
    stack.axis = .vertical
    stack.spacing = 15
    stack.translatesAutoresizingMaskIntoConstraints = false
    let scroll = UIScrollView()
    scroll.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(scroll)
    scroll.addSubview(stack)
    NSLayoutConstraint.activate([
      scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
      scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 28),
      stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -28),
      stack.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
      stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -64),
    ])
    func text(_ value: String, _ style: UIFont.TextStyle) {
      let label = UILabel()
      label.text = value
      label.font = .preferredFont(forTextStyle: style)
      label.numberOfLines = 0
      stack.addArrangedSubview(label)
    }
    text("Text-following ink PROTOTYPE", .largeTitle)
    text(
      "Aim: find out whether your handwriting stays connected to book text when an EPUB changes layout.",
      .title2)
    text(
      "Choose one walkthrough. Each has its own sample, notes, controls, checks and answer. Start with the first; no walkthrough depends on another.",
      .body)
    text(
      "This experiment asks you to select words first, then write an ink group for them. It moves and scales the whole group with the first selected fragment. It does not recognize your intentions or solve arbitrary freehand reflow. Judge these limits as well as the result.",
      .body)
    for (index, scenario) in ReflowScenario.all.enumerated() {
      let path = Self.root.appending(path: scenario.id).appending(path: "review.json")
      let saved = (try? Data(contentsOf: path)).flatMap {
        try? JSONDecoder().decode(ReflowReview.self, from: $0)
      }
      let suffix = saved?.answer == nil ? "Not reviewed" : "Answer saved"
      let button = UIButton(configuration: .tinted())
      button.configuration?.title = "\(index + 1). \(scenario.title)"
      button.configuration?.subtitle = suffix
      button.contentHorizontalAlignment = .leading
      button.addAction(
        UIAction { [weak self] _ in
          let controller = ReflowController(index: index)
          controller.modalPresentationStyle = .fullScreen
          self?.present(controller, animated: true)
        }, for: .touchUpInside)
      stack.addArrangedSubview(button)
      scenarioButtons.append(button)
    }
    let reviewed = ReflowScenario.all.filter { scenario in
      let path = Self.root.appending(path: scenario.id).appending(path: "review.json")
      return (try? Data(contentsOf: path)).flatMap {
        try? JSONDecoder().decode(ReflowReview.self, from: $0)
      }?.answer != nil
    }.count
    summary.text = "\(reviewed) of \(ReflowScenario.all.count) walkthroughs reviewed."
    summary.numberOfLines = 0
    summary.font = .preferredFont(forTextStyle: .headline)
    stack.addArrangedSubview(summary)
    let earlier = UIButton(configuration: .plain())
    earlier.setTitle("Open the earlier preserved-page walkthroughs", for: .normal)
    earlier.addAction(
      UIAction { [weak self] _ in self?.present(ExperimentController(), animated: true) },
      for: .touchUpInside)
    stack.addArrangedSubview(earlier)
    if let arg = ProcessInfo.processInfo.arguments.first(where: {
      $0.hasPrefix("--reflow-scenario=")
    }),
      let index = ReflowScenario.all.firstIndex(where: {
        $0.id == arg.components(separatedBy: "=").last
      })
    {
      DispatchQueue.main.async { [weak self] in
        let controller = ReflowController(index: index)
        controller.modalPresentationStyle = .fullScreen
        self?.present(controller, animated: false)
      }
    }
  }
}

@MainActor
final class ReflowController: UIViewController, WKScriptMessageHandler, PKCanvasViewDelegate,
  UIGestureRecognizerDelegate
{
  let index: Int
  var scenario: ReflowScenario { ReflowScenario.all[index] }
  var probe: Bool { ProcessInfo.processInfo.arguments.contains("--reflow-probe") }
  var folder: URL {
    ReflowHomeController.root.appending(path: (probe ? "PROBE-" : "") + scenario.id)
  }
  var review: ReflowReview
  var drawings: [String: PKDrawing] = [:]
  var active = 0
  var projection = CGAffineTransform.identity
  var latestPacket: [String: Any] = [:]
  var drawingActive = false
  var applying = false
  var writing = false
  var activeAvailable = false
  var lastSequence = 0
  var projectedGroupID: String?
  var history: [[String: Any]] = []
  let server = ReflowServer()
  var web: WKWebView!
  let canvas = PKCanvasView()
  let picker = PKToolPicker()
  let reader = UIView()
  let status = UILabel()
  let selected = UILabel()
  let instruction = UILabel()
  let checkButton = UIButton(configuration: .tinted())
  let nextButton = UIButton(configuration: .filled())
  let actionButton = UIButton(configuration: .tinted())
  let writeButton = UIButton(configuration: .tinted())
  let bottom = UIStackView()
  let highlights = CAShapeLayer()
  var previews: [UIImageView] = []
  var pan: UIPanGestureRecognizer!

  init(index: Int) {
    self.index = index
    let prefix = ProcessInfo.processInfo.arguments.contains("--reflow-probe") ? "PROBE-" : ""
    let path = ReflowHomeController.root.appending(path: prefix + ReflowScenario.all[index].id)
      .appending(path: "review.json")
    review =
      (try? Data(contentsOf: path)).flatMap {
        try? JSONDecoder().decode(ReflowReview.self, from: $0)
      }
      ?? ReflowReview(tried: Array(repeating: false, count: ReflowScenario.all[index].steps.count))
    super.init(nibName: nil, bundle: nil)
  }
  required init?(coder: NSCoder) { fatalError() }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    reader.overrideUserInterfaceStyle = .light
    let config = WKWebViewConfiguration()
    config.userContentController.add(self, name: "reflow")
    web = WKWebView(frame: .zero, configuration: config)
    web.scrollView.isScrollEnabled = false
    web.isInspectable = true
    let column = UIStackView()
    column.axis = .vertical
    column.spacing = 9
    column.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(column)
    NSLayoutConstraint.activate([
      column.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
      column.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
      column.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
      column.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
    ])
    let heading = UILabel()
    heading.text = scenario.title
    heading.font = .preferredFont(forTextStyle: .title2)
    let home = button("All walkthroughs") { [weak self] in
      guard let self else { return }
      self.save()
      self.picker.setVisible(false, forFirstResponder: self.canvas)
      self.web.configuration.userContentController.removeScriptMessageHandler(forName: "reflow")
      self.web.stopLoading()
      self.server.stop()
      self.dismiss(animated: true)
    }
    let restart = button("Restart this walkthrough") { [weak self] in self?.restart() }
    column.addArrangedSubview(row([home, heading, restart]))
    let aim = UILabel()
    aim.text = scenario.aim
    aim.numberOfLines = 0
    aim.font = .preferredFont(forTextStyle: .body)
    column.addArrangedSubview(aim)
    selected.text = "Writing off. Long-press words on the page to choose a target."
    selected.numberOfLines = 2
    selected.font = .preferredFont(forTextStyle: .subheadline)
    column.addArrangedSubview(selected)
    writeButton.addAction(UIAction { [weak self] _ in self?.toggleWriting() }, for: .touchUpInside)
    let link = button("Link selected words") { [weak self] in self?.js("window.reflow.select()") }
    let switchNote = button("Edit next note") { [weak self] in self?.switchGroup() }
    let undo = button("Undo") { [weak self] in self?.canvas.undoManager?.undo() }
    let redo = button("Redo") { [weak self] in self?.canvas.undoManager?.redo() }
    column.addArrangedSubview(row([writeButton, link, switchNote, undo, redo]))
    column.addArrangedSubview(reader)
    reader.heightAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
    reader.clipsToBounds = true
    reader.addSubview(web)
    highlights.fillColor = UIColor.systemBlue.withAlphaComponent(0.13).cgColor
    reader.layer.addSublayer(highlights)
    reader.addSubview(canvas)
    canvas.backgroundColor = .clear
    canvas.isOpaque = false
    canvas.isScrollEnabled = false
    canvas.drawingPolicy =
      ProcessInfo.processInfo.arguments.contains("--simulator-input") ? .anyInput : .pencilOnly
    canvas.maximumSupportedContentVersion = .version4
    picker.maximumSupportedContentVersion = .version4
    canvas.tool = PKInkingTool(
      .pen, color: UIColor.label.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)),
      width: 3)
    canvas.delegate = self
    picker.addObserver(canvas)
    pan = UIPanGestureRecognizer(target: self, action: #selector(navigateWhileWriting(_:)))
    pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
    pan.delegate = self
    pan.cancelsTouchesInView = false
    pan.isEnabled = false
    reader.addGestureRecognizer(pan)
    status.numberOfLines = 2
    status.font = .preferredFont(forTextStyle: .caption1)
    column.addArrangedSubview(status)
    bottom.axis = .vertical
    bottom.spacing = 8
    column.addArrangedSubview(bottom)
    for group in review.groups {
      if let data = try? Data(contentsOf: folder.appending(path: group.id + ".drawing")) {
        drawings[group.id] = try? PKDrawing(data: data)
      }
    }
    updateWriting()
    renderStep()
    do {
      try server.start { [weak self] port in
        Task { @MainActor [weak self] in
          guard let self else { return }
          self.web.load(
            URLRequest(
              url: URL(
                string:
                  "http://127.0.0.1:\(port)/Fixtures/Reflow/index.html?chapter=\(self.index)\(self.probe ? "&probe=1" : "")"
              )!))
        }
      }
    } catch { status.text = error.localizedDescription }
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    web.frame = reader.bounds
    canvas.frame = reader.bounds
    canvas.contentSize = reader.bounds.size
  }

  func button(_ title: String, action: @escaping @MainActor () -> Void) -> UIButton {
    let b = UIButton(configuration: .tinted())
    b.setTitle(title, for: .normal)
    b.addAction(UIAction { _ in action() }, for: .touchUpInside)
    return b
  }
  func row(_ views: [UIView]) -> UIStackView {
    let stack = UIStackView(arrangedSubviews: views)
    stack.spacing = 8
    return stack
  }
  func js(_ source: String) {
    web.evaluateJavaScript(source + ";void 0") { [weak self] _, error in
      if let error { self?.status.text = error.localizedDescription }
    }
  }
  func syncGroups() {
    guard let data = try? JSONEncoder().encode(review.groups),
      let text = String(data: data, encoding: .utf8)
    else { return }
    let target = review.groups.indices.contains(active) ? review.groups[active].cfi : ""
    let focus = String(data: try! JSONEncoder().encode(target), encoding: .utf8)!
    js("window.reflow.setGroups(\(text),\(focus))")
  }
  func toggleWriting() {
    guard !review.groups.isEmpty else {
      status.text = "Select words, then tap Link selected words before writing."
      return
    }
    writing.toggle()
    updateWriting()
  }
  func updateWriting() {
    canvas.isDrawingEnabled = writing && activeAvailable
    canvas.isUserInteractionEnabled = writing
    pan?.isEnabled = writing
    writeButton.setTitle(writing ? "Writing ON" : "Writing OFF", for: .normal)
    if writing { canvas.becomeFirstResponder() } else { canvas.resignFirstResponder() }
    picker.setVisible(writing, forFirstResponder: canvas)
  }
  func switchGroup() {
    guard !review.groups.isEmpty else { return }
    save()
    active = (active + 1) % review.groups.count
    let group = review.groups[active]
    let encoded = String(data: try! JSONEncoder().encode(group.cfi), encoding: .utf8)!
    js("window.reflow.focus(\(encoded))")
    applyGeometry()
  }

  func userContentController(
    _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
  ) {
    guard let packet = message.body as? [String: Any], let type = packet["type"] as? String else {
      return
    }
    if type == "ready" {
      let hash = packet["sourceHash"] as? String ?? ""
      guard review.sourceHash.isEmpty || review.sourceHash == hash else {
        status.text =
          "The sample source changed. Existing notes were kept; they will not be attached to different words."
        return
      }
      let savedFont = review.lastFont
      review.sourceHash = hash
      syncGroups()
      if savedFont != 24 { js("window.reflow.restoreFont(\(savedFont))") }
      if probe {
        if review.groups.isEmpty { js("window.reflowProbe.selectOccurrence(1)") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
          self?.js("window.reflowProbe.sequence()")
        }
      }
      return
    }
    if type == "error" {
      status.text = packet["message"] as? String
      return
    }
    if type == "selection" {
      selected.text =
        "Selected: \(packet["text"] as? String ?? ""). Tap Link selected words to start a note."
      return
    }
    if type == "selected" {
      guard review.groups.count < 12, let cfi = packet["cfi"] as? String,
        let quote = packet["quote"] as? String, quote.count <= 500,
        let rects = packet["rects"] as? [[String: Double]], let r = rects.first
      else {
        status.text =
          "This experiment allows up to 12 notes, each linked to at most 500 characters."
        return
      }
      let origin = ReflowRect(
        x: r["x"] ?? 0, y: r["y"] ?? 0, width: r["width"] ?? 0, height: r["height"] ?? 0)
      let group = ReflowInkGroup(
        id: UUID().uuidString, cfi: cfi, quote: quote,
        sourceHash: packet["sourceHash"] as? String ?? "",
        prefix: packet["prefix"] as? String ?? "",
        suffix: packet["suffix"] as? String ?? "", font: packet["font"] as? Double ?? 24,
        origin: origin)
      review.groups.append(group)
      drawings[group.id] = PKDrawing()
      active = review.groups.count - 1
      projection = .identity
      projectedGroupID = group.id
      applying = true
      canvas.drawing = PKDrawing()
      applying = false
      canvas.undoManager?.removeAllActions()
      selected.text = "Note \(active + 1) belongs to: \(quote). Turn writing ON to add its ink."
      syncGroups()
      save()
      return
    }
    if type == "geometry" {
      let sequence = packet["sequence"] as? Int ?? 0
      guard sequence > lastSequence else { return }
      lastSequence = sequence
      latestPacket = packet
      review.lastFont = packet["font"] as? Double ?? review.lastFont
      if drawingActive {
        status.text =
          "The layout changed during a stroke. Ink placement waits until the stroke ends."
      } else {
        applyGeometry()
      }
      if probe, !review.groups.isEmpty, drawings[review.groups[0].id]?.strokes.isEmpty != false {
        let r = review.groups[0].origin
        let paths: [[CGPoint]] = [
          [CGPoint(x: r.x, y: r.y + r.height), CGPoint(x: r.x + r.width, y: r.y + r.height)],
          [
            CGPoint(x: r.x + r.width / 2, y: r.y), CGPoint(x: r.x + r.width / 2 + 40, y: r.y - 30),
            CGPoint(x: r.x + r.width / 2 + 110, y: r.y - 30),
          ],
          [CGPoint(x: r.x + 120, y: r.y - 40), CGPoint(x: r.x + 120, y: r.y - 15)],
        ]
        let strokes = paths.map { points in
          PKStroke(
            ink: PKInk(.pen, color: .black),
            path: PKStrokePath(
              controlPoints: points.enumerated().map { i, point in
                PKStrokePoint(
                  location: point, timeOffset: Double(i) * 0.05, size: CGSize(width: 3, height: 3),
                  opacity: 1, force: 0.7, azimuth: 0, altitude: .pi / 2)
              }, creationDate: Date()))
        }
        let drawing = PKDrawing(strokes: strokes)
        drawings[review.groups[0].id] = drawing
        applying = true
        canvas.drawing = drawing.transformed(using: projection)
        applying = false
        try? drawing.dataRepresentation().write(
          to: folder.appending(path: review.groups[0].id + ".drawing"), options: .atomic)
      }
      var record = packet
      record["canonicalInkHashes"] = drawings.mapValues { digest($0.dataRepresentation()) }
      record["canonicalStrokeCounts"] = drawings.mapValues { $0.strokes.count }
      record["projection"] = [
        "a": projection.a, "d": projection.d, "tx": projection.tx, "ty": projection.ty,
      ]
      record["inputEvidence"] =
        probe
        ? "Synthetic native PKStroke probe; programmatically selected the second useful; no human answers"
        : "User authoring requires live physical confirmation"
      history.append(record)
      if history.count > 60 { history.removeFirst(history.count - 60) }
      save()
      if probe, let reason = packet["reason"] as? String,
        ["bigger", "narrow", "smaller", "paginated"].contains(reason)
      {
        let currentGeneration = packet["generation"] as? Int
        let drawing = canvas.drawing
        web.takeSnapshot(with: nil) { [weak self] image, _ in
          guard let self, let image, self.latestPacket["generation"] as? Int == currentGeneration
          else { return }
          let ink = drawing.image(from: self.reader.bounds, scale: 2)
          let composed = UIGraphicsImageRenderer(size: self.reader.bounds.size).image { _ in
            image.draw(in: self.reader.bounds)
            ink.draw(in: self.reader.bounds)
          }
          try? composed.pngData()?.write(
            to: self.folder.appending(path: "probe-\(reason).png"), options: .atomic)
        }
      }
    }
  }

  func applyGeometry() {
    guard let resolved = latestPacket["groups"] as? [[String: Any]] else { return }
    for preview in previews { preview.removeFromSuperview() }
    previews.removeAll()
    let path = UIBezierPath()
    var boxes: [CGRect] = []
    var warnings: [String] = []
    var activeVisible = false
    for (i, group) in review.groups.enumerated() {
      guard let match = resolved.first(where: { $0["id"] as? String == group.id }),
        let rects = match["rects"] as? [[String: Double]], let first = rects.first,
        match["status"] as? String == "resolved"
      else { continue }
      for rect in (match["visible"] as? [[String: Double]] ?? []) {
        path.append(
          UIBezierPath(
            rect: CGRect(
              x: rect["x"] ?? 0, y: rect["y"] ?? 0, width: rect["width"] ?? 0,
              height: rect["height"] ?? 0)))
      }
      if rects.count > 1 {
        warnings.append(
          "Note \(i + 1) spans \(rects.count) fragments; judge the literal mark carefully.")
      }
      let scale = (latestPacket["font"] as? Double ?? 24) / group.font
      let transform = CGAffineTransform(
        a: scale, b: 0, c: 0, d: scale,
        tx: (first["x"] ?? 0) - group.origin.x * scale,
        ty: (first["y"] ?? 0) - group.origin.y * scale)
      let display = (drawings[group.id] ?? PKDrawing()).transformed(using: transform)
      if !display.strokes.isEmpty {
        boxes.append(display.bounds)
        if !reader.bounds.contains(display.bounds) {
          warnings.append("Some of note \(i + 1) is outside the reading area.")
        }
      }
      if i == active {
        activeVisible = true
        if projection != transform || projectedGroupID != group.id {
          applying = true
          projection = transform
          canvas.drawing = display
          applying = false
          projectedGroupID = group.id
          canvas.undoManager?.removeAllActions()
        }
        selected.text = "Editing note \(i + 1) of \(review.groups.count): \(group.quote)"
      } else if !display.strokes.isEmpty {
        let image = UIImageView(
          image: display.image(from: display.bounds, scale: traitCollection.displayScale))
        image.frame = display.bounds
        image.isUserInteractionEnabled = false
        reader.insertSubview(image, belowSubview: canvas)
        previews.append(image)
      }
    }
    for (i, box) in boxes.enumerated() {
      if boxes.dropFirst(i + 1).contains(where: { $0.intersects(box) }) {
        warnings.append("Notes may overlap. Check their actual handwriting.")
        break
      }
    }
    activeAvailable = activeVisible
    canvas.isDrawingEnabled = writing && activeAvailable
    if !activeVisible {
      applying = true
      canvas.drawing = PKDrawing()
      applying = false
      projectedGroupID = nil
      if !review.groups.isEmpty {
        warnings.append(
          "The selected note is on another page. Turn writing off and select new words to start a note here."
        )
      }
    }
    highlights.path = path.cgPath
    status.text =
      warnings.isEmpty
      ? "\(review.groups.count) notes linked to selected words. Ink stays visible with writing off."
      : warnings.joined(separator: " ")
  }

  func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) { drawingActive = true }
  func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
    drawingActive = false
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in self?.applyGeometry() }
  }
  func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
    guard !applying, activeAvailable, review.groups.indices.contains(active) else { return }
    let group = review.groups[active]
    let drawing = canvas.drawing.transformed(using: projection.inverted())
    drawings[group.id] = drawing
    do {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try drawing.dataRepresentation().write(
        to: folder.appending(path: group.id + ".drawing"), options: .atomic)
      save()
    } catch { status.text = "Ink could not be saved: \(error.localizedDescription)" }
  }
  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
  ) -> Bool { true }
  @objc func navigateWhileWriting(_ gesture: UIPanGestureRecognizer) {
    if latestPacket["flow"] as? String == "scrolled" {
      let delta = gesture.translation(in: reader)
      js("window.reflow.scroll(\(-delta.y))")
      gesture.setTranslation(.zero, in: reader)
      return
    }
    if gesture.state == .ended {
      let delta = gesture.translation(in: reader)
      if abs(delta.x) > 45 { js("window.reflow.go('\(delta.x < 0 ? "next" : "prev")')") }
    }
  }

  func save() {
    do {
      review.question = scenario.question
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(review).write(to: folder.appending(path: "review.json"), options: .atomic)
      if !latestPacket.isEmpty {
        var packet = latestPacket
        packet["deviceModel"] = UIDevice.current.model
        packet["iPadOS"] = UIDevice.current.systemVersion
        packet["appBuild"] = Bundle.main.infoDictionary?["CFBundleVersion"]
        packet["inputEvidence"] =
          ProcessInfo.processInfo.arguments.contains("--simulator-input")
          ? "Simulator input; no physical Pencil verdict"
          : "Physical input must be confirmed by user"
        packet["appProcessLifetimePeakRSS"] = processLifetimePeakRSS()
        try JSONSerialization.data(withJSONObject: packet, options: [.prettyPrinted, .sortedKeys])
          .write(to: folder.appending(path: "geometry.json"), options: .atomic)
        try JSONSerialization.data(withJSONObject: history, options: [.prettyPrinted, .sortedKeys])
          .write(to: folder.appending(path: "geometry-history.json"), options: .atomic)
      }
    } catch { status.text = "This walkthrough could not be saved: \(error.localizedDescription)" }
  }

  func renderStep() {
    for child in bottom.arrangedSubviews {
      bottom.removeArrangedSubview(child)
      child.removeFromSuperview()
    }
    if review.step >= scenario.steps.count {
      renderVerdict()
      return
    }
    let step = scenario.steps[review.step]
    instruction.text = "Step \(review.step + 1) of \(scenario.steps.count): \(step.instruction)"
    instruction.font = .preferredFont(forTextStyle: .body)
    instruction.numberOfLines = 0
    bottom.addArrangedSubview(instruction)
    if let action = step.action, let title = step.button {
      let actionButton = button(title) { [weak self] in self?.perform(action) }
      bottom.addArrangedSubview(actionButton)
    }
    let check = button((review.tried[review.step] ? "☑ " : "☐ ") + step.check) { [weak self] in
      guard let self else { return }
      self.review.tried[self.review.step].toggle()
      self.save()
      self.renderStep()
    }
    let next = button("Continue") { [weak self] in
      guard let self else { return }
      self.review.step += 1
      self.save()
      self.renderStep()
    }
    next.isEnabled = review.tried[review.step]
    bottom.addArrangedSubview(row([check, next]))
    bottom.addArrangedSubview(
      button("I could not complete this step") { [weak self] in self?.renderVerdict() })
  }
  func perform(_ action: String) {
    writing = false
    updateWriting()
    save()
    for group in review.groups {
      let url = folder.appending(path: group.id + "-original.drawing")
      if !FileManager.default.fileExists(atPath: url.path), let drawing = drawings[group.id] {
        try? drawing.dataRepresentation().write(to: url, options: .atomic)
      }
    }
    review.layoutActions.append(action)
    let commands: [String]
    switch action {
    case "wrap": commands = ["narrow", "bigger"]
    case "unwrap": commands = ["wide", "smaller"]
    case "cycle": commands = ["smaller", "bigger"]
    case "crowd": commands = ["narrow", "bigger"]
    case "reload":
      js("window.reflow.reload()")
      return
    default: commands = [action]
    }
    let expression = commands.map { "await window.reflow.layout('\($0)')" }.joined(separator: ";")
    js("(async()=>{\(expression)})()")
  }
  func renderVerdict() {
    for child in bottom.arrangedSubviews {
      bottom.removeArrangedSubview(child)
      child.removeFromSuperview()
    }
    let question = UILabel()
    question.text = scenario.question
    question.numberOfLines = 0
    question.font = .preferredFont(forTextStyle: .headline)
    bottom.addArrangedSubview(question)
    let feedback = UITextField()
    feedback.placeholder = "What should change? Optional comment"
    feedback.borderStyle = .roundedRect
    feedback.text = review.feedback
    bottom.addArrangedSubview(feedback)
    for answer in [scenario.success, "No, this needs changes", "I could not judge this"] {
      bottom.addArrangedSubview(
        button(answer) { [weak self, weak feedback] in
          guard let self else { return }
          self.review.answer = answer
          self.review.feedback = feedback?.text ?? ""
          self.save()
          self.status.text = "Answer saved for this walkthrough: \(answer)"
        })
    }
    bottom.addArrangedSubview(
      button("Review the steps again") { [weak self] in
        self?.review.step = 0
        self?.save()
        self?.renderStep()
      })
  }

  func restart() {
    let alert = UIAlertController(
      title: "Restart only this walkthrough?",
      message:
        "This removes this walkthrough's test notes and answers. Other reflow walkthroughs and all earlier preserved-page notes stay saved.",
      preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "Keep my notes", style: .cancel))
    alert.addAction(
      UIAlertAction(title: "Restart this walkthrough", style: .destructive) { [weak self] _ in
        guard let self else { return }
        do {
          if FileManager.default.fileExists(atPath: self.folder.path) {
            try FileManager.default.removeItem(at: self.folder)
          }
          self.review = ReflowReview(
            tried: Array(repeating: false, count: self.scenario.steps.count))
          self.drawings = [:]
          self.active = 0
          self.writing = false
          self.projectedGroupID = nil
          self.applying = true
          self.canvas.drawing = PKDrawing()
          self.applying = false
          self.updateWriting()
          self.syncGroups()
          self.js("window.reflow.reset()")
          self.renderStep()
          self.save()
        } catch {
          self.status.text = "The walkthrough could not be restarted: \(error.localizedDescription)"
        }
      })
    present(alert, animated: true)
  }
}
