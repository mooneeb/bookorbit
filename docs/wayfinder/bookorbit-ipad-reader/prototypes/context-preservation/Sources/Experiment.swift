import CryptoKit
import PDFKit
import PencilKit
import UIKit
import WebKit

enum Scenario: String, CaseIterable, Codable {
  case scroll, columns, pdf, missing

  var title: String {
    switch self {
    case .scroll: "EPUB: original scrolled excerpt"
    case .columns: "EPUB: original column excerpt"
    case .pdf: "PDF: cropped and rotated page"
    case .missing: "EPUB: missing image blocks capture"
    }
  }

  var aim: String {
    switch self {
    case .scroll:
      "Circle useful and write in the margin. Compare two captures of this middle-of-chapter excerpt."
    case .columns:
      "Mark useful and the margin. Check that both captures retain these columns at a nonzero horizontal offset."
    case .pdf:
      "Mark the word and page corners. Check the crop and rotation in both retained candidates."
    case .missing:
      "The illustration is deliberately missing. Write a mark, then try capture. It must not claim the excerpt is preserved."
    }
  }

  var checks: [String] {
    if self == .missing {
      return [
        "I saw the missing-resource failure.",
        "No complete archive or source-removal action was offered.",
        "My scratch ink remains after reopening this scenario.",
      ]
    }
    return [
      "I compared Raster and Fixed page at 1x, 2x, and 4x, including margins and ink alignment.",
      "After removing the scratch source and fully restarting, I could read the excerpt and edit/erase/undo ink.",
      "I checked the current exported preview in my Mac and Android browsers, including quote context.",
    ]
  }
}

struct ArchiveRecord: Codable {
  var scenario: Scenario
  var os: String
  var sourceSHA256: String
  var context: [String: String]
  var geometry: [String: Double]
  var captureMilliseconds: Double
  var processLifetimePeakRSSBefore: Int64
  var processLifetimePeakRSSAfter: Int64
  var rasterWidth: Int
  var rasterHeight: Int
  var fixedPageError: String?
  var sourceRemoved = false
  var inkRevision = 1
  var launchID: String
  var reopenedLaunchIDs: [String] = []
  var checks = [false, false, false]
  var verdict = "Not reviewed"
  var feedback = ""
  var inputEvidence: String?
}

enum ExperimentFailure: LocalizedError {
  case message(String)
  var errorDescription: String? {
    switch self {
    case .message(let message): message
    }
  }
}

struct ScratchStore {
  static let root = URL.documentsDirectory.appending(path: "PROTOTYPE-WIPE-ME")
  let scenario: Scenario
  var folder: URL { Self.root.appending(path: scenario.rawValue) }
  var source: URL { folder.appending(path: "source") }
  var retained: URL { folder.appending(path: "retained") }
  var hasSource: Bool { FileManager.default.fileExists(atPath: source.path) }

  func prepareDirectories() throws {
    try FileManager.default.createDirectory(at: retained, withIntermediateDirectories: true)
  }

  func readRecord() throws -> ArchiveRecord? {
    let url = retained.appending(path: "record.json")
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try JSONDecoder().decode(ArchiveRecord.self, from: Data(contentsOf: url))
  }

  func writeRecord(_ record: ArchiveRecord) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(record).write(to: retained.appending(path: "record.json"), options: .atomic)
  }

  func write(_ data: Data, _ name: String) throws {
    guard data.count <= 16 * 1024 * 1024 else {
      throw ExperimentFailure.message("Candidate exceeds this experiment's 16 MiB per-file cap.")
    }
    try data.write(to: retained.appending(path: name), options: .atomic)
  }

  func drawing() throws -> PKDrawing {
    let url = retained.appending(path: "ink.drawing")
    guard FileManager.default.fileExists(atPath: url.path) else { return PKDrawing() }
    return try PKDrawing(data: Data(contentsOf: url))
  }

  func reset() throws {
    if FileManager.default.fileExists(atPath: folder.path) {
      try FileManager.default.removeItem(at: folder)
    }
  }

}

func processLifetimePeakRSS() -> Int64 {
  var usage = rusage()
  getrusage(RUSAGE_SELF, &usage)
  return Int64(usage.ru_maxrss)
}

func digest(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func fixturePDF() -> Data {
  let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 720, height: 540)).pdfData {
    renderer in
    renderer.beginPage()
    let context = renderer.cgContext
    UIColor.white.setFill()
    context.fill(CGRect(x: 0, y: 0, width: 720, height: 540))
    let attributes: [NSAttributedString.Key: Any] = [
      .font: UIFont.systemFont(ofSize: 26), .foregroundColor: UIColor.black,
    ]
    ("ORIGINAL PDF: useful observation" as NSString).draw(
      at: CGPoint(x: 80, y: 90), withAttributes: attributes)
    ("Crop origin (48, 36). Intrinsic rotation 90 degrees." as NSString).draw(
      at: CGPoint(x: 80, y: 140), withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
    UIColor.systemGreen.withAlphaComponent(0.25).setFill()
    context.fill(CGRect(x: 90, y: 220, width: 350, height: 140))
    UIColor.black.setStroke()
    context.setLineWidth(3)
    context.stroke(CGRect(x: 60, y: 48, width: 600, height: 440))
    for (index, point) in [
      CGPoint(x: 60, y: 48), CGPoint(x: 610, y: 48), CGPoint(x: 60, y: 450),
      CGPoint(x: 610, y: 450),
    ].enumerated() {
      ("\(index + 1)" as NSString).draw(at: point, withAttributes: attributes)
    }
  }
  let document = PDFDocument(data: data)!
  document.page(at: 0)!.setBounds(CGRect(x: 48, y: 36, width: 624, height: 468), for: .cropBox)
  document.page(at: 0)!.rotation = 90
  return document.dataRepresentation()!
}

func drawPDF(_ data: Data, in rect: CGRect, context: CGContext) throws {
  guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider),
    let page = document.page(at: 1)
  else {
    throw ExperimentFailure.message("Fixed-page output could not be opened.")
  }
  context.saveGState()
  context.translateBy(x: 0, y: rect.height)
  context.scaleBy(x: 1, y: -1)
  context.concatenate(
    page.getDrawingTransform(.cropBox, rect: rect, rotate: 0, preserveAspectRatio: true))
  context.clip(to: page.getBoxRect(.cropBox))
  context.drawPDFPage(page)
  context.restoreGState()
}

func pdfImage(_ data: Data, size: CGSize, scale: CGFloat = 2) throws -> UIImage {
  let format = UIGraphicsImageRendererFormat()
  format.scale = scale
  var failure: Error?
  let image = UIGraphicsImageRenderer(size: size, format: format).image { renderer in
    UIColor.white.setFill()
    renderer.fill(CGRect(origin: .zero, size: size))
    do {
      try drawPDF(data, in: CGRect(origin: .zero, size: size), context: renderer.cgContext)
    } catch { failure = error }
  }
  if let failure { throw failure }
  return image
}

func htmlEscape(_ text: String) -> String {
  text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
    .replacingOccurrences(of: "\"", with: "&quot;")
}

@MainActor
final class CaptureSurface: UIView, UIScrollViewDelegate {
  let scroll = UIScrollView()
  let page = UIView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
  let background = UIImageView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
  let canvas = PKCanvasView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
  var web: WKWebView?
  var fit: CGFloat = 1

  init() {
    super.init(frame: .zero)
    scroll.delegate = self
    scroll.maximumZoomScale = 4
    scroll.backgroundColor = .secondarySystemBackground
    addSubview(scroll)
    scroll.addSubview(page)
    page.backgroundColor = .white
    page.addSubview(background)
    page.addSubview(canvas)
    canvas.backgroundColor = .clear
    canvas.isOpaque = false
    canvas.isScrollEnabled = false
    canvas.contentSize = page.bounds.size
    canvas.overrideUserInterfaceStyle = .light
    canvas.drawingPolicy =
      ProcessInfo.processInfo.arguments.contains("--simulator-input") ? .anyInput : .pencilOnly
    canvas.tool = PKInkingTool(.pen, color: .black, width: 3)
  }

  required init?(coder: NSCoder) { fatalError() }
  override func layoutSubviews() {
    super.layoutSubviews()
    scroll.frame = bounds
    fit = min(bounds.width / 640, bounds.height / 480, 1)
    scroll.minimumZoomScale = fit
    if scroll.zoomScale < fit { scroll.zoomScale = fit }
    scroll.contentSize = page.bounds.size
  }

  func viewForZooming(in scrollView: UIScrollView) -> UIView? { page }

  func attachWeb() -> WKWebView {
    removeWeb()
    let view = WKWebView(frame: page.bounds)
    view.overrideUserInterfaceStyle = .light
    view.scrollView.isScrollEnabled = false
    page.insertSubview(view, belowSubview: canvas)
    web = view
    return view
  }

  func removeWeb() {
    web?.stopLoading()
    web?.navigationDelegate = nil
    web?.removeFromSuperview()
    web = nil
  }

  func show(_ image: UIImage) {
    removeWeb()
    background.image = image
  }
}

@main
@MainActor
final class AppDelegate: UIResponder, UIApplicationDelegate {}

@MainActor
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?
  func scene(
    _ scene: UIScene, willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    guard let windowScene = scene as? UIWindowScene else { return }
    let window = UIWindow(windowScene: windowScene)
    window.rootViewController = ExperimentController()
    window.makeKeyAndVisible()
    self.window = window
  }
}

@MainActor
final class ExperimentController: UIViewController, WKNavigationDelegate, PKCanvasViewDelegate,
  UITextViewDelegate
{
  let surface = CaptureSurface()
  let picker = PKToolPicker()
  let status = UILabel()
  let aim = UILabel()
  let contextLabel = UILabel()
  let progress = UILabel()
  let scenarioButton = UIButton(type: .system)
  let primary = UIButton(type: .system)
  let writeButton = UIButton(type: .system)
  let candidates = UISegmentedControl(items: ["Raster", "Fixed page"])
  let zoom = UISegmentedControl(items: ["1x", "2x", "4x"])
  let review = UIStackView()
  let verdict = UISegmentedControl(items: ["Keep", "Change", "Cannot judge"])
  let feedback = UITextView()
  var checkButtons: [UIButton] = []
  var scenario = Scenario.scroll
  var store: ScratchStore { ScratchStore(scenario: scenario) }
  var record: ArchiveRecord?
  var ready = false
  var writing = false
  var suppressInkSave = false
  var details: [String: Any] = [:]
  var primaryAction: (() async throws -> Void)?
  let launchID = UUID().uuidString
  var automatic = ProcessInfo.processInfo.arguments.contains("--capture-fixtures")
  var webContinuation: CheckedContinuation<Void, Error>?

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    let scroll = UIScrollView()
    scroll.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(scroll)
    NSLayoutConstraint.activate([
      scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
      scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
    ])
    let stack = UIStackView()
    stack.axis = .vertical
    stack.spacing = 12
    stack.translatesAutoresizingMaskIntoConstraints = false
    scroll.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 20),
      stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -30),
      stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 24),
      stack.trailingAnchor.constraint(
        equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -24),
    ])
    func label(_ text: String, _ style: UIFont.TextStyle) -> UILabel {
      let label = UILabel()
      label.text = text
      label.numberOfLines = 0
      label.font = .preferredFont(forTextStyle: style)
      return label
    }
    stack.addArrangedSubview(label("Keep old notes readable", .title1))
    stack.addArrangedSubview(
      label(
        "PROTOTYPE: after a book is replaced, can its original excerpt and editable ink still reopen? Each scenario is independent. This does not test normal EPUB reflow.",
        .body))
    progress.font = .preferredFont(forTextStyle: .footnote)
    stack.addArrangedSubview(progress)
    scenarioButton.showsMenuAsPrimaryAction = true
    scenarioButton.contentHorizontalAlignment = .leading
    scenarioButton.menu = UIMenu(
      children: Scenario.allCases.map { item in
        UIAction(title: item.title) { [weak self] _ in self?.start(item) }
      })
    stack.addArrangedSubview(scenarioButton)
    aim.numberOfLines = 0
    stack.addArrangedSubview(aim)
    status.numberOfLines = 0
    status.font = .preferredFont(forTextStyle: .callout)
    stack.addArrangedSubview(status)
    primary.configuration = .filled()
    primary.addAction(UIAction { [weak self] _ in self?.performPrimary() }, for: .touchUpInside)
    writeButton.addAction(UIAction { [weak self] _ in self?.toggleWriting() }, for: .touchUpInside)
    let reset = UIButton(type: .system)
    reset.setTitle("Restart this scenario", for: .normal)
    reset.addAction(UIAction { [weak self] _ in self?.confirmReset() }, for: .touchUpInside)
    let actions = UIStackView(arrangedSubviews: [primary, writeButton, reset])
    actions.spacing = 16
    stack.addArrangedSubview(actions)
    surface.heightAnchor.constraint(equalToConstant: 500).isActive = true
    stack.addArrangedSubview(surface)
    candidates.selectedSegmentIndex = 0
    candidates.addAction(UIAction { [weak self] _ in self?.showCandidate() }, for: .valueChanged)
    zoom.selectedSegmentIndex = 0
    zoom.addAction(UIAction { [weak self] _ in self?.setZoom() }, for: .valueChanged)
    let comparison = UIStackView(arrangedSubviews: [candidates, zoom])
    comparison.spacing = 16
    stack.addArrangedSubview(comparison)
    contextLabel.numberOfLines = 0
    contextLabel.font = .preferredFont(forTextStyle: .footnote)
    stack.addArrangedSubview(contextLabel)
    review.axis = .vertical
    review.spacing = 10
    stack.addArrangedSubview(review)
    verdict.addAction(UIAction { [weak self] _ in self?.saveReview() }, for: .valueChanged)
    stack.addArrangedSubview(
      label(
        "Your verdict is separate from the checks. Which candidate looks acceptable, at what zoom, and what should happen on failure?",
        .body))
    stack.addArrangedSubview(verdict)
    feedback.heightAnchor.constraint(equalToConstant: 90).isActive = true
    feedback.backgroundColor = .secondarySystemBackground
    feedback.font = .preferredFont(forTextStyle: .body)
    feedback.delegate = self
    stack.addArrangedSubview(feedback)
    let export = UIButton(type: .system)
    export.setTitle("Export current preview and review", for: .normal)
    export.addAction(UIAction { [weak self] _ in self?.sharePreview() }, for: .touchUpInside)
    stack.addArrangedSubview(export)
    let replacement = UIButton(type: .system)
    replacement.setTitle("Inspect revised quote without moving this note", for: .normal)
    replacement.addAction(
      UIAction { [weak self] _ in self?.inspectReplacement() }, for: .touchUpInside)
    stack.addArrangedSubview(replacement)
    surface.canvas.delegate = self
    picker.addObserver(surface.canvas)
    Task { await runInitial() }
  }

  func runInitial() async {
    if automatic {
      var failures: [String] = []
      var missingResourceError = ""
      for item in [Scenario.scroll, .columns, .pdf] {
        do {
          scenario = item
          try store.reset()
          try await loadScenario()
          surface.canvas.drawing = syntheticInk()
          try saveInk()
          try await capture()
          try removeSource()
        } catch { failures.append("\(item.rawValue): \(error.localizedDescription)") }
      }
      scenario = .missing
      do {
        try store.reset()
        try await loadScenario()
        failures.append("missing: resource error was not detected")
      } catch {
        missingResourceError = String(describing: error)
        status.text = "Expected readiness failure: \(error.localizedDescription)"
      }
      let output: [String: Any] = [
        "os": UIDevice.current.systemVersion, "syntheticInkOnly": true, "failures": failures,
        "launchID": launchID,
        "missingResourceError": missingResourceError,
        "missingArchiveAbsent": !FileManager.default.fileExists(
          atPath: store.retained.appending(path: "record.json").path),
      ]
      try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
        .write(to: ScratchStore.root.appending(path: "capture-run.json"), options: .atomic)
      automatic = false
      start(.scroll)
    } else if ProcessInfo.processInfo.arguments.contains("--reopen-fixtures") {
      var outputs: [[String: Any]] = []
      for item in [Scenario.scroll, .columns, .pdf] {
        scenario = item
        do {
          try await loadScenario()
          outputs.append([
            "scenario": item.rawValue, "sourceAbsent": !store.hasSource,
            "strokes": surface.canvas.drawing.strokes.count,
            "originalQuoteAvailable": record?.context["quote"] != nil, "launchID": launchID,
          ])
        } catch {
          outputs.append(["scenario": item.rawValue, "error": error.localizedDescription])
        }
      }
      try? JSONSerialization.data(withJSONObject: outputs, options: [.prettyPrinted, .sortedKeys])
        .write(to: ScratchStore.root.appending(path: "cold-reopen-run.json"), options: .atomic)
      start(.scroll)
    } else {
      let argument = ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--scenario=") }
      start(argument.flatMap { Scenario(rawValue: String($0.dropFirst(11))) } ?? .scroll)
    }
  }

  func start(_ item: Scenario) {
    Task {
      scenario = item
      do { try await loadScenario() } catch { showFailure(error) }
    }
  }

  func loadScenario() async throws {
    primary.isEnabled = false
    scenarioButton.isEnabled = false
    primaryAction = nil
    contextLabel.text = ""
    candidates.isEnabled = false
    ready = false
    record = nil
    writing = false
    surface.removeWeb()
    surface.background.image = nil
    surface.scroll.setZoomScale(surface.fit, animated: false)
    candidates.selectedSegmentIndex = 0
    zoom.selectedSegmentIndex = 0
    scenarioButton.setTitle(scenario.title, for: .normal)
    aim.text = scenario.aim
    status.text = "Opening this scenario's own scratch files..."
    details = [:]
    try store.prepareDirectories()
    record = try store.readRecord()
    if record != nil {
      for name in ["background.png", "ink.drawing"]
      where !FileManager.default.fileExists(atPath: store.retained.appending(path: name).path) {
        throw ExperimentFailure.message(
          "Retained file \(name) is missing. Do not remove the source or reset this scenario before collecting the files."
        )
      }
    }
    suppressInkSave = true
    surface.canvas.drawing = try store.drawing()
    suppressInkSave = false
    buildReview()
    setWriting()
    if var existing = record {
      if !existing.reopenedLaunchIDs.contains(launchID) {
        existing.reopenedLaunchIDs.append(launchID)
        record = existing
        try store.writeRecord(existing)
      }
      ready = true
      showCandidate()
      refreshArchiveState()
      scenarioButton.isEnabled = true
      return
    }
    if !store.hasSource {
      try FileManager.default.createDirectory(at: store.source, withIntermediateDirectories: true)
      if scenario == .pdf {
        try fixturePDF().write(to: store.source.appending(path: "original.pdf"), options: .atomic)
      } else {
        guard let seedFolder = Bundle.main.url(forResource: "Fixtures", withExtension: nil) else {
          throw ExperimentFailure.message(
            "This no-seed build can only reopen retained scenarios. Install the normal build to start a new fixture."
          )
        }
        let seed = seedFolder.appending(path: "EPUB")
        try FileManager.default.copyItem(at: seed, to: store.source.appending(path: "EPUB"))
        if scenario == .missing {
          try FileManager.default.removeItem(
            at: store.source.appending(path: "EPUB/OEBPS/diagram.svg"))
        }
      }
    }
    if scenario == .pdf {
      let data = try Data(contentsOf: store.source.appending(path: "original.pdf"))
      surface.show(try pdfImage(data, size: surface.page.bounds.size))
      details = [
        "quote": "ORIGINAL PDF: useful observation", "href": "original.pdf#page=1",
        "prefix": "Original self-authored PDF",
        "suffix": "Crop origin (48, 36). Intrinsic rotation 90 degrees.",
      ]
    } else {
      let web = surface.attachWeb()
      web.navigationDelegate = self
      try await withCheckedThrowingContinuation { continuation in
        webContinuation = continuation
        web.loadFileURL(
          store.source.appending(path: "EPUB/OEBPS/chapter.xhtml"),
          allowingReadAccessTo: store.source)
      }
      let mode = scenario == .columns ? "columns" : "scroll"
      let result = try await web.callAsyncJavaScript(
        "return await prepareFixture(mode)", arguments: ["mode": mode], in: nil, contentWorld: .page
      )
      guard let dictionary = result as? [String: Any] else {
        throw ExperimentFailure.message("No resource-readiness result.")
      }
      details = dictionary
      try store.write(
        JSONSerialization.data(withJSONObject: details, options: [.prettyPrinted, .sortedKeys]),
        "readiness.json")
      let offset = (details[scenario == .columns ? "scrollX" : "scrollY"] as? Double) ?? 0
      guard offset > 0 else {
        throw ExperimentFailure.message("Fixture did not reach its required nonzero offset.")
      }
    }
    ready = true
    status.text =
      "1. Turn Ink ON and write a mark. Then capture both candidates. Original source is present."
    primary.setTitle("2. Capture both candidates", for: .normal)
    primaryAction = { [weak self] in try await self?.capture() }
    primary.isEnabled = true
    scenarioButton.isEnabled = true
    candidates.isEnabled = false
    contextLabel.text =
      "Only this 640 x 480 point excerpt is captured. Ink is stored separately. No BookOrbit connection."
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    webContinuation?.resume()
    webContinuation = nil
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    webContinuation?.resume(throwing: error)
    webContinuation = nil
  }

  func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) {
    self.webView(webView, didFail: navigation, withError: error)
  }

  func capture() async throws {
    guard ready else {
      throw ExperimentFailure.message(
        "Required resources are not ready. No complete archive was saved. Scratch ink is kept.")
    }
    guard !surface.canvas.drawing.strokes.isEmpty else {
      throw ExperimentFailure.message("Write at least one mark before comparing captures.")
    }
    primary.isEnabled = false
    status.text = "Capturing the background without flattening the editable ink..."
    let started = Date()
    let memoryBefore = processLifetimePeakRSS()
    let image: UIImage
    var fixed: Data?
    var fixedError: String?
    if scenario == .pdf {
      let data = try Data(contentsOf: store.source.appending(path: "original.pdf"))
      image = try pdfImage(data, size: surface.page.bounds.size)
      fixed = PDFDocument(data: data)?.page(at: 0)?.dataRepresentation
    } else {
      guard let web = surface.web else {
        throw ExperimentFailure.message("Source view is not available.")
      }
      let snapshot = WKSnapshotConfiguration()
      snapshot.rect = web.bounds
      snapshot.snapshotWidth = 640
      image = try await web.takeSnapshot(configuration: snapshot)
      let configuration = WKPDFConfiguration()
      configuration.rect = CGRect(origin: web.scrollView.contentOffset, size: web.bounds.size)
      do { fixed = try await web.pdf(configuration: configuration) } catch {
        fixedError = error.localizedDescription
      }
    }
    guard let png = image.pngData(), let cgImage = image.cgImage,
      cgImage.width * cgImage.height <= 8_000_000
    else {
      throw ExperimentFailure.message("Raster is unavailable or exceeds the experiment's 8 MP cap.")
    }
    try store.write(png, "background.png")
    if let fixed { try store.write(fixed, "background.pdf") }
    if fixed == nil && fixedError == nil { fixedError = "No fixed-page output returned." }
    let sourceFile =
      scenario == .pdf
      ? store.source.appending(path: "original.pdf")
      : store.source.appending(path: "EPUB/OEBPS/chapter.xhtml")
    let context = details.reduce(into: [String: String]()) { result, pair in
      if ["quote", "href", "prefix", "suffix", "font"].contains(pair.key) {
        result[pair.key] = String(describing: pair.value)
      }
    }
    var geometry = details.reduce(into: [String: Double]()) { result, pair in
      if let value = pair.value as? Double { result[pair.key] = value }
    }
    geometry["canvasWidth"] = 640
    geometry["canvasHeight"] = 480
    if scenario == .pdf {
      geometry.merge([
        "cropX": 48, "cropY": 36, "cropWidth": 624, "cropHeight": 468, "intrinsicRotation": 90,
      ]) { _, new in new }
    }
    record = ArchiveRecord(
      scenario: scenario, os: UIDevice.current.systemVersion,
      sourceSHA256: digest(try Data(contentsOf: sourceFile)), context: context, geometry: geometry,
      captureMilliseconds: Date().timeIntervalSince(started) * 1000,
      processLifetimePeakRSSBefore: memoryBefore,
      processLifetimePeakRSSAfter: processLifetimePeakRSS(), rasterWidth: cgImage.width,
      rasterHeight: cgImage.height,
      fixedPageError: fixedError, launchID: launchID)
    record?.inputEvidence =
      automatic
      ? "Synthetic strokes in an automated simulator fixture run"
      : "Manual input; physical Pencil review must be recorded separately"
    try saveInk()
    try store.writeRecord(record!)
    surface.show(image)
    try exportPreview()
    refreshArchiveState()
  }

  func removeSource() throws {
    guard record != nil else {
      throw ExperimentFailure.message("No complete retained background exists.")
    }
    surface.removeWeb()
    if store.hasSource { try FileManager.default.removeItem(at: store.source) }
    record?.sourceRemoved = true
    try store.writeRecord(record!)
    try exportPreview()
    refreshArchiveState()
  }

  func refreshArchiveState() {
    guard let record else { return }
    candidates.isEnabled = true
    primary.isEnabled = true
    let cold = record.launchID != launchID
    if store.hasSource {
      status.text =
        "2. Compare Raster and Fixed page below. Then remove this scenario's original scratch source."
      primary.setTitle("3. Remove scratch source", for: .normal)
      primaryAction = { [weak self] in try self?.removeSource() }
    } else {
      status.text =
        cold
        ? "3. Reopened in a new app process. Source is absent. Read, erase, add ink, and Undo. Then export the current preview."
        : "3. Source removed. Fully close the app in the app switcher, then reopen it offline. Do not reinstall or restart the scenario."
      primary.setTitle("Reopen retained files", for: .normal)
      primaryAction = { [weak self] in try await self?.loadScenario() }
    }
    let failure = record.fixedPageError.map { " Fixed-page candidate failed: \($0)" } ?? ""
    contextLabel.text =
      "Original quote: \(record.context["quote"] ?? "missing")\nThis note still belongs to the original content. Ink is saved locally; export again after changing it.\(failure)"
    updateProgress()
  }

  func showCandidate() {
    guard let record else { return }
    do {
      let image: UIImage
      if candidates.selectedSegmentIndex == 0 {
        guard
          let raster = UIImage(
            contentsOfFile: store.retained.appending(path: "background.png").path)
        else { throw ExperimentFailure.message("Retained raster is missing.") }
        image = raster
      } else {
        if let failure = record.fixedPageError { throw ExperimentFailure.message(failure) }
        image = try pdfImage(
          Data(contentsOf: store.retained.appending(path: "background.pdf")),
          size: surface.page.bounds.size, scale: max(2, pow(2, Double(zoom.selectedSegmentIndex))))
      }
      surface.show(image)
      refreshArchiveState()
    } catch {
      status.text =
        "This candidate failed: \(error.localizedDescription). The other candidate and ink remain available."
    }
  }

  func setZoom() {
    surface.scroll.setZoomScale(
      surface.fit * pow(2, Double(zoom.selectedSegmentIndex)), animated: false)
    if record != nil { showCandidate() }
  }

  func toggleWriting() {
    writing.toggle()
    setWriting()
  }
  func setWriting() {
    writeButton.setTitle(writing ? "Ink ON" : "Ink OFF", for: .normal)
    surface.canvas.isUserInteractionEnabled = writing
    picker.setVisible(writing, forFirstResponder: surface.canvas)
    if writing {
      surface.canvas.becomeFirstResponder()
    } else {
      surface.canvas.resignFirstResponder()
    }
  }

  func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
    guard !suppressInkSave else { return }
    do {
      try saveInk()
      if record != nil { refreshArchiveState() }
    } catch { showFailure(error) }
  }

  func saveInk() throws {
    try store.prepareDirectories()
    try store.write(surface.canvas.drawing.dataRepresentation(), "ink.drawing")
    if record != nil {
      record?.inkRevision += 1
      try store.writeRecord(record!)
    }
  }

  func performPrimary() {
    Task {
      do { try await primaryAction?() } catch { showFailure(error) }
    }
  }

  func showFailure(_ error: Error) {
    scenarioButton.isEnabled = true
    let javascriptMessage = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String
    let explanation =
      javascriptMessage?.contains("EncodingError") == true
      ? "The required illustration is missing or could not load." : error.localizedDescription
    status.text = "Excerpt not preserved: \(explanation) Your scratch ink is kept."
    primary.setTitle("Try capture", for: .normal)
    primaryAction = { [weak self] in try await self?.capture() }
    primary.isEnabled = true
    candidates.isEnabled = record != nil
  }

  func confirmReset() {
    let alert = UIAlertController(
      title: "Restart only this scenario?",
      message:
        "This deletes its PROTOTYPE scratch ink, retained files, and review. Other scenarios are kept.",
      preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    alert.addAction(
      UIAlertAction(title: "Restart", style: .destructive) { [weak self] _ in
        guard let self else { return }
        do {
          try store.reset()
          start(scenario)
        } catch { showFailure(error) }
      })
    present(alert, animated: true)
  }

  func buildReview() {
    for child in review.arrangedSubviews {
      review.removeArrangedSubview(child)
      child.removeFromSuperview()
    }
    checkButtons = scenario.checks.enumerated().map { index, text in
      let button = UIButton(type: .system)
      button.contentHorizontalAlignment = .leading
      button.titleLabel?.numberOfLines = 0
      button.setTitle(text, for: .normal)
      button.isSelected = record?.checks[index] ?? false
      button.setImage(
        UIImage(systemName: button.isSelected ? "checkmark.square" : "square"), for: .normal)
      button.addAction(
        UIAction { [weak self, weak button] _ in
          button?.isSelected.toggle()
          button?.setImage(
            UIImage(systemName: button?.isSelected == true ? "checkmark.square" : "square"),
            for: .normal)
          self?.saveReview()
        }, for: .touchUpInside)
      review.addArrangedSubview(button)
      return button
    }
    verdict.selectedSegmentIndex =
      ["Keep", "Change", "Cannot judge"].firstIndex(of: record?.verdict ?? "")
      ?? UISegmentedControl.noSegment
    feedback.text = record?.feedback ?? ""
    if record == nil,
      let data = try? Data(contentsOf: store.retained.appending(path: "failure-review.json")),
      let review = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    {
      let checks = review["checks"] as? [Bool] ?? [false, false, false]
      for (index, button) in checkButtons.enumerated() {
        button.isSelected = checks[index]
        button.setImage(
          UIImage(systemName: checks[index] ? "checkmark.square" : "square"), for: .normal)
      }
      verdict.selectedSegmentIndex =
        ["Keep", "Change", "Cannot judge"].firstIndex(of: review["verdict"] as? String ?? "")
        ?? UISegmentedControl.noSegment
      feedback.text = review["feedback"] as? String ?? ""
    }
    updateProgress()
  }

  func textViewDidChange(_ textView: UITextView) { saveReview() }
  func saveReview() {
    do {
      let result =
        verdict.selectedSegmentIndex < 0
        ? "Not reviewed" : verdict.titleForSegment(at: verdict.selectedSegmentIndex)!
      if record != nil {
        record?.checks = checkButtons.map(\.isSelected)
        record?.verdict = result
        record?.feedback = feedback.text
        try store.writeRecord(record!)
      } else {
        let review: [String: Any] = [
          "checks": checkButtons.map(\.isSelected), "verdict": result,
          "feedback": feedback.text ?? "",
        ]
        try store.write(
          JSONSerialization.data(withJSONObject: review, options: [.prettyPrinted, .sortedKeys]),
          "failure-review.json")
      }
      updateProgress()
    } catch { showFailure(error) }
  }

  func updateProgress() {
    let reviewed = Scenario.allCases.filter { item in
      let scratch = ScratchStore(scenario: item)
      if let existing = try? scratch.readRecord() {
        return existing.checks.allSatisfy { $0 } && existing.verdict != "Not reviewed"
      }
      if let data = try? Data(contentsOf: scratch.retained.appending(path: "failure-review.json")),
        let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      {
        return (result["checks"] as? [Bool])?.allSatisfy { $0 } == true
          && result["verdict"] as? String != "Not reviewed"
      }
      return false
    }.count
    progress.text =
      "\(reviewed) of 4 scenarios reviewed. Checks mean tried, including failures. Keep/Change records your reaction."
  }

  func exportPreview() throws {
    guard let record else {
      throw ExperimentFailure.message("Capture this scenario before exporting a preview.")
    }
    let rect = surface.page.bounds
    let ink = surface.canvas.drawing.image(from: rect, scale: 2)
    guard let inkData = ink.pngData() else {
      throw ExperimentFailure.message("Ink preview could not be rendered.")
    }
    try store.write(inkData, "ink-preview.png")
    let background = try Data(contentsOf: store.retained.appending(path: "background.png"))
    var fixedHTML =
      "<p>Fixed-page candidate failed: \(htmlEscape(record.fixedPageError ?? "not available"))</p>"
    if record.fixedPageError == nil {
      let fixed = try pdfImage(
        Data(contentsOf: store.retained.appending(path: "background.pdf")), size: rect.size)
      if let data = fixed.pngData() {
        fixedHTML = figure(
          data, inkData, title: "Fixed page rendered at 2x for this portable preview")
      }
    }
    let html = """
      <!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
      <title>Original annotation context: \(scenario.rawValue)</title>
      <style>body{font:18px system-ui;max-width:850px;margin:24px auto;padding:0 16px;background:#f3f3f1;color:#222}figure{margin:16px 0;overflow:auto}section{position:relative;width:640px;height:480px;background:white}img{position:absolute;width:640px;height:480px;inset:0}button{padding:10px;margin:8px}pre{white-space:pre-wrap}</style>
      <h1>Can you still read the original note?</h1><p>PROTOTYPE: saved source-replacement context, not normal EPUB reflow or BookOrbit sync. This single file contains its images and current ink preview. No font, original book, WebArchive, or PencilKit decoder is needed.</p>
      <p>\(htmlEscape(scenario.title)). iPadOS/simulator \(htmlEscape(record.os)). Ink revision \(record.inkRevision). Source absent at export: \(!store.hasSource).</p>
        <p>Input evidence: \(htmlEscape(record.inputEvidence ?? "Not recorded; do not treat this as physical Pencil evidence"))</p>
      <p>Compare both examples. Check the text, illustration, margins and translucent ink. Use browser zoom or horizontal scrolling to inspect enlarged display. Fixed-page native zoom can retain more detail than this 2x browser derivative.</p>
      \(figure(background, inkData, title: "Raster background plus current ink"))\(fixedHTML)
      <h2>Original context</h2><p>\(htmlEscape(record.context["quote"] ?? ""))</p><p>Before: \(htmlEscape(record.context["prefix"] ?? ""))<br>After: \(htmlEscape(record.context["suffix"] ?? ""))</p><p>Original anchor: \(htmlEscape(record.context["href"] ?? "")). This note has not been moved to a revised edition.</p>
      <h2>Your review</h2><p>\(htmlEscape(record.verdict)): \(htmlEscape(record.feedback))</p><p>Report browser/version, preferred candidate, acceptable zoom, visual defects, and whether the failure message is clear. Viewing this file does not tick the native checklist.</p></html>
      """
    try store.write(Data(html.utf8), "preview.html")
  }

  func figure(_ background: Data, _ ink: Data, title: String) -> String {
    "<h2>\(title)</h2><figure><section><img alt=\"Original book excerpt\" src=\"data:image/png;base64,\(background.base64EncodedString())\"><img alt=\"Current handwriting, viewing only\" src=\"data:image/png;base64,\(ink.base64EncodedString())\"></section></figure>"
  }

  func sharePreview() {
    do {
      let files: [URL]
      if scenario == .missing && record == nil {
        saveReview()
        files = [
          store.retained.appending(path: "failure-review.json"),
          store.retained.appending(path: "ink.drawing"),
        ].filter { FileManager.default.fileExists(atPath: $0.path) }
      } else {
        try exportPreview()
        files = [
          store.retained.appending(path: "preview.html"),
          store.retained.appending(path: "record.json"),
        ]
      }
      let controller = UIActivityViewController(activityItems: files, applicationActivities: nil)
      controller.popoverPresentationController?.sourceView = view
      controller.popoverPresentationController?.sourceRect = CGRect(
        x: view.bounds.midX, y: view.bounds.maxY - 50, width: 1, height: 1)
      present(controller, animated: true)
    } catch { showFailure(error) }
  }

  func inspectReplacement() {
    guard let record else {
      status.text = "Capture this scenario before comparing revised context."
      return
    }
    let original = record.context["quote"] ?? ""
    let revised = original.replacingOccurrences(of: "useful", with: "revised")
    do {
      try store.write(Data(revised.utf8), "revised-quote.txt")
      let alert = UIAlertController(
        title: "This note still belongs to the original",
        message:
          "Original quote:\n\(original)\n\nRevised quote:\n\(revised)\n\nThe preserved page and ink have not moved. This experiment has no relink action; approval and migration behavior are still a later decision.",
        preferredStyle: .alert)
      alert.addAction(UIAlertAction(title: "Keep original context", style: .default))
      present(alert, animated: true)
    } catch { showFailure(error) }
  }

  func syntheticInk() -> PKDrawing {
    let x = (details["wordX"] as? Double) ?? 180
    let y = (details["wordY"] as? Double) ?? 160
    let lines: [[CGPoint]] = [
      [CGPoint(x: x, y: y + 28), CGPoint(x: x + 75, y: y + 28)],
      [
        CGPoint(x: x + 60, y: y + 35), CGPoint(x: x + 150, y: y + 90),
        CGPoint(x: x + 140, y: y + 70),
      ],
      [CGPoint(x: 8, y: 8), CGPoint(x: 24, y: 8), CGPoint(x: 24, y: 24)],
      [CGPoint(x: 610, y: 450), CGPoint(x: 630, y: 450), CGPoint(x: 630, y: 470)],
    ]
    return PKDrawing(
      strokes: lines.enumerated().map { index, line in
        let points = line.enumerated().map { step, point in
          PKStrokePoint(
            location: point, timeOffset: Double(step) * 0.1,
            size: CGSize(width: index == 0 ? 12 : 3, height: index == 0 ? 12 : 3),
            opacity: index == 0 ? 0.4 : 1, force: 0.5, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(
          ink: PKInk(index == 0 ? .marker : .pen, color: index == 0 ? .systemYellow : .black),
          path: PKStrokePath(controlPoints: points, creationDate: Date()))
      })
  }
}
