import CryptoKit
import PDFKit
import PencilKit
import UIKit
import WebKit

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
  static let guidedRoot = root.appending(path: "guided-walkthroughs")
  let scenario: Scenario
  var folder: URL { Self.guidedRoot.appending(path: scenario.rawValue) }
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
    ("A useful observation" as NSString).draw(
      at: CGPoint(x: 80, y: 90), withAttributes: attributes)
    ("A small note can bring an old idea back into focus." as NSString).draw(
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
    throw ExperimentFailure.message("The PDF copy could not be opened.")
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
    scroll.contentSize = CGSize(width: 640 * scroll.zoomScale, height: 480 * scroll.zoomScale)
    centerPage()
  }

  func viewForZooming(in scrollView: UIScrollView) -> UIView? { page }

  func scrollViewDidZoom(_ scrollView: UIScrollView) { centerPage() }

  func centerPage() {
    scroll.contentInset = UIEdgeInsets(
      top: max(0, (bounds.height - scroll.contentSize.height) / 2),
      left: max(0, (bounds.width - scroll.contentSize.width) / 2), bottom: 0, right: 0)
  }

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
    window.rootViewController =
      ProcessInfo.processInfo.arguments.contains(where: {
        $0.hasPrefix("--scenario=") || $0 == "--capture-fixtures"
      }) ? ExperimentController() : ReflowHomeController()
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
  let pageScroll = UIScrollView()
  let stack = UIStackView()
  let status = UILabel()
  let primary = UIButton(type: .system)
  let writeButton = UIButton(type: .system)
  let feedback = UITextView()
  var checkControls: [UIButton] = []
  var answerControls: [(UIButton, String)] = []
  var scenario = Scenario.scroll
  var store: ScratchStore { ScratchStore(scenario: scenario) }
  var record: ArchiveRecord?
  var walkthrough = WalkthroughReview()
  var ready = false
  var writing = false
  var suppressInkSave = false
  var loading = false
  var showingHome = false
  var details: [String: Any] = [:]
  let launchID = UUID().uuidString
  var automatic = ProcessInfo.processInfo.arguments.contains("--capture-fixtures")
  var webContinuation: CheckedContinuation<Void, Error>?
  var step: WalkthroughStep { scenario.steps[min(walkthrough.stepIndex, scenario.steps.count - 1)] }
  let activeURL = ScratchStore.root.appending(path: "active-walkthrough.txt")

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    pageScroll.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(pageScroll)
    NSLayoutConstraint.activate([
      pageScroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      pageScroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
      pageScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      pageScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
    ])
    stack.axis = .vertical
    stack.spacing = 16
    stack.translatesAutoresizingMaskIntoConstraints = false
    pageScroll.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: pageScroll.contentLayoutGuide.topAnchor, constant: 20),
      stack.bottomAnchor.constraint(
        equalTo: pageScroll.contentLayoutGuide.bottomAnchor, constant: -30),
      stack.leadingAnchor.constraint(
        equalTo: pageScroll.frameLayoutGuide.leadingAnchor, constant: 28),
      stack.trailingAnchor.constraint(
        equalTo: pageScroll.frameLayoutGuide.trailingAnchor, constant: -28),
    ])
    surface.heightAnchor.constraint(equalToConstant: 380).isActive = true
    primary.configuration = .filled()
    primary.titleLabel?.numberOfLines = 0
    primary.addAction(UIAction { [weak self] _ in self?.performPrimary() }, for: .touchUpInside)
    writeButton.addAction(UIAction { [weak self] _ in self?.toggleWriting() }, for: .touchUpInside)
    feedback.heightAnchor.constraint(equalToConstant: 88).isActive = true
    feedback.backgroundColor = .secondarySystemBackground
    feedback.font = .preferredFont(forTextStyle: .body)
    feedback.delegate = self
    surface.canvas.delegate = self
    picker.addObserver(surface.canvas)
    Task { await runInitial() }
  }

  func label(_ text: String, _ style: UIFont.TextStyle = .body) -> UILabel {
    let label = UILabel()
    label.text = text
    label.numberOfLines = 0
    label.font = .preferredFont(forTextStyle: style)
    label.adjustsFontForContentSizeCategory = true
    return label
  }

  func button(_ text: String, action: @escaping () -> Void) -> UIButton {
    let button = UIButton(type: .system)
    button.configuration = .tinted()
    button.contentHorizontalAlignment = .leading
    button.titleLabel?.numberOfLines = 0
    button.setTitle(text, for: .normal)
    button.addAction(UIAction { _ in action() }, for: .touchUpInside)
    return button
  }

  func clearScreen() {
    writing = false
    setWriting()
    for child in stack.arrangedSubviews {
      stack.removeArrangedSubview(child)
      child.removeFromSuperview()
    }
    pageScroll.setContentOffset(.zero, animated: false)
  }

  func showHome() {
    guard !loading else { return }
    showingHome = true
    try? FileManager.default.removeItem(at: activeURL)
    clearScreen()
    stack.addArrangedSubview(label("Saved pages and handwriting", .largeTitle))
    stack.addArrangedSubview(
      label("PROTOTYPE: can an old note stay readable when its book changes?"))
    stack.addArrangedSubview(
      label(
        "Choose one walkthrough. It gives you its own sample page, instructions and questions. You can do them in any order. Nothing connects to your real library.",
        .callout))
    let finished = Scenario.allCases.filter {
      (try? ScratchStore(scenario: $0).readWalkthrough().finished) == true
    }.count
    stack.addArrangedSubview(
      label("\(finished) of \(Scenario.allCases.count) walkthroughs finished", .subheadline))
    stack.addArrangedSubview(
      label(
        "Start here: Check a saved EPUB page. It only asks you to write, save, and inspect the result. Offline checks are separate.",
        .callout))
    for (index, item) in Scenario.allCases.enumerated() {
      let heading: String? =
        switch index {
        case 0: "Page clarity"
        case 3: "Offline recovery"
        case 5: "When saving fails"
        case 6: "Viewing on other devices"
        case 9: "Original words"
        case 10: "App installation"
        default: nil
        }
      if let heading { stack.addArrangedSubview(label(heading, .headline)) }
      let saved = try? ScratchStore(scenario: item).readWalkthrough()
      let state =
        saved?.finished == true ? "Reviewed" : (saved?.stepIndex ?? 0) > 0 ? "In progress" : "Ready"
      stack.addArrangedSubview(
        button("\(index + 1). \(item.title)  ·  \(state)") { [weak self] in self?.start(item) })
    }
    let earlier = [Scenario.scroll, .columns, .pdf].filter {
      FileManager.default.fileExists(
        atPath: ScratchStore.root.appending(path: "\($0.rawValue)/retained/background.png").path)
    }
    if !earlier.isEmpty {
      stack.addArrangedSubview(label("Earlier prototype notes", .headline))
      stack.addArrangedSubview(
        label("Your earlier ink is kept. The new walkthroughs use fresh samples.", .footnote))
      for item in earlier {
        stack.addArrangedSubview(
          button(
            "View earlier \(item.fixture == .pdf ? "PDF" : item.fixture == .columns ? "column EPUB" : "EPUB") note"
          ) { [weak self] in self?.showEarlierNote(item) })
      }
    }
  }

  func showEarlierNote(_ item: Scenario) {
    let folder = ScratchStore.root.appending(path: "\(item.rawValue)/retained")
    let controller = UIViewController()
    controller.view.backgroundColor = .systemBackground
    let content = UIStackView()
    content.axis = .vertical
    content.spacing = 20
    content.translatesAutoresizingMaskIntoConstraints = false
    controller.view.addSubview(content)
    NSLayoutConstraint.activate([
      content.topAnchor.constraint(
        equalTo: controller.view.safeAreaLayoutGuide.topAnchor, constant: 24),
      content.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor, constant: 24),
      content.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor, constant: -24),
    ])
    content.addArrangedSubview(label("Earlier saved note", .title1))
    content.addArrangedSubview(
      label(
        "This is your page from before the walkthrough redesign. This viewing copy and its original editable ink file have been kept.",
        .callout))
    let saved = CaptureSurface()
    saved.heightAnchor.constraint(equalToConstant: 400).isActive = true
    if let image = UIImage(contentsOfFile: folder.appending(path: "background.png").path) {
      saved.show(image)
    }
    if let data = try? Data(contentsOf: folder.appending(path: "ink.drawing")),
      let ink = try? PKDrawing(data: data)
    {
      saved.canvas.drawing = ink
    }
    saved.canvas.isUserInteractionEnabled = false
    content.addArrangedSubview(saved)
    content.addArrangedSubview(
      button("Close earlier note") { [weak controller] in controller?.dismiss(animated: true) })
    present(controller, animated: true)
  }

  func renderStep() {
    guard !automatic, !showingHome else { return }
    clearScreen()
    checkControls = []
    answerControls = []
    stack.addArrangedSubview(button("‹ All walkthroughs") { [weak self] in self?.showHome() })
    stack.addArrangedSubview(label(scenario.title, .title1))
    stack.addArrangedSubview(label("Testing: \(scenario.aim)", .callout))
    if walkthrough.finished {
      stack.addArrangedSubview(label("Walkthrough finished", .title2))
      stack.addArrangedSubview(
        label(
          "Your answers are saved on this iPad. A reported problem still counts as a completed check."
        ))
      for item in scenario.steps where !item.question.isEmpty {
        if let answer = walkthrough.answers[item.id] {
          stack.addArrangedSubview(label(item.title, .headline))
          stack.addArrangedSubview(label(answer))
          if let comment = walkthrough.comments[item.id], !comment.isEmpty {
            stack.addArrangedSubview(label(comment, .callout))
          }
        }
      }
      if let problem = walkthrough.answers["save-problem"] {
        stack.addArrangedSubview(label("Could not finish saving: \(problem)"))
      }
      if scenario == .replacement {
        stack.addArrangedSubview(
          button("Retry with the page comparison") { [weak self] in
            guard let self else { return }
            do {
              let encoder = JSONEncoder()
              encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
              try store.write(encoder.encode(walkthrough), "before-visual-comparison-review.json")
              walkthrough.finished = false
              walkthrough.stepIndex = 1
              walkthrough.checks["quote"] = [false, false]
              walkthrough.answers.removeValue(forKey: "quote")
              persistWalkthrough()
              renderStep()
            } catch { showFailure(error) }
          })
      }
      stack.addArrangedSubview(
        button("Review my steps and answers") { [weak self] in
          guard let self else { return }
          walkthrough.finished = false
          walkthrough.stepIndex = 0
          persistWalkthrough()
          renderStep()
        })
      addRestart()
      return
    }
    let current = step
    stack.addArrangedSubview(
      label(
        "Step \(walkthrough.stepIndex + 1) of \(scenario.steps.count): \(current.title)", .title2))
    stack.addArrangedSubview(label(current.instruction))
    status.numberOfLines = 0
    status.font = .preferredFont(forTextStyle: .callout)
    status.textColor = .secondaryLabel
    status.text = stateDescription()
    stack.addArrangedSubview(status)
    if case .share = current.kind {
    } else if case .browser = current.kind {
    } else {
      stack.addArrangedSubview(surface)
    }
    switch current.kind {
    case .write, .edit, .maintenance:
      stack.addArrangedSubview(writeButton)
    case .failure:
      stack.addArrangedSubview(
        button("Reopen this sample") { [weak self] in
          guard let self else { return }
          Task {
            do {
              try await loadScenario()
              walkthrough.actions["failure-reopened"] = true
              persistWalkthrough()
              renderStep()
            } catch { showFailure(error) }
          }
        })
    case .share:
      stack.addArrangedSubview(button("Share saved page") { [weak self] in self?.sharePreview() })
    case .quote:
      stack.addArrangedSubview(
        button("Compare original and revised pages") { [weak self] in self?.inspectReplacement() })
    default: break
    }
    if !current.checks.isEmpty {
      stack.addArrangedSubview(
        label("Try each item, then tick it. Tick it even if you found a problem.", .footnote))
      let checked =
        walkthrough.checks[current.id] ?? Array(repeating: false, count: current.checks.count)
      for (index, text) in current.checks.enumerated() {
        let control = button(text) { [weak self] in self?.toggleCheck(index) }
        control.setImage(
          UIImage(systemName: checked[index] ? "checkmark.square.fill" : "square"), for: .normal)
        checkControls.append(control)
        stack.addArrangedSubview(control)
      }
      stack.addArrangedSubview(label(current.question, .headline))
      for answer in current.answers {
        let selected = walkthrough.answers[current.id] == answer
        let control = button(answer) { [weak self] in self?.chooseAnswer(answer) }
        control.setImage(
          UIImage(systemName: selected ? "largecircle.fill.circle" : "circle"), for: .normal)
        answerControls.append((control, answer))
        stack.addArrangedSubview(control)
      }
      stack.addArrangedSubview(label(current.commentPrompt, .footnote))
      feedback.text = walkthrough.comments[current.id] ?? ""
      stack.addArrangedSubview(feedback)
    }
    primary.setTitle(primaryTitle(), for: .normal)
    primary.isEnabled = mayContinue()
    stack.addArrangedSubview(primary)
    if walkthrough.stepIndex > 0 {
      stack.addArrangedSubview(
        button("Previous step") { [weak self] in
          guard let self else { return }
          walkthrough.stepIndex -= 1
          persistWalkthrough()
          renderStep()
        })
    }
    addRestart()
    setWriting()
    view.layoutIfNeeded()
    showCandidate()
  }

  func addRestart() {
    stack.addArrangedSubview(
      button("Start this walkthrough again…") { [weak self] in self?.confirmReset() })
  }

  func stateDescription() -> String {
    switch step.kind {
    case .write:
      if record != nil {
        return
          "This walkthrough already has your saved page and ink. Continue with it, or add ink before continuing."
      }
      return scenario == .missing
        ? "The empty picture is deliberate. Saving should be refused, while your handwriting is kept."
        : "This sample belongs only to this walkthrough. Saving keeps this visible page and your editable handwriting together."
    case .view(let pdf, let scale):
      return
        "Saved as \(pdf ? "PDF copy" : "page image") · \(scale)x. You are inspecting this saved view, not changing the book's font size."
    case .offline:
      let cold = record?.launchID != launchID
      return
        "Sample book: \(store.hasSource ? "still present" : "removed"). App reopened since saving: \(cold ? "yes" : "not yet"). Confirm the iPad's internet setting yourself."
    case .failure:
      return
        "\(walkthrough.lastMessage) Reopened sample: \(walkthrough.actions["failure-reopened"] == true ? "yes" : "not yet"). Your writing is saved locally."
    case .maintenance:
      let marker = FileManager.default.fileExists(
        atPath: store.retained.appending(path: "local-unsent-marker.txt").path)
      let build =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
      return
        "Installed build: \(build). Local unsent-note marker: \(marker ? "present" : "missing"). App reopened since saving: \(record?.launchID != launchID ? "yes" : "not yet"). Original sentence: \(record?.context["quote"] ?? "unavailable")."
    case .quote: return "Original sentence: \(record?.context["quote"] ?? "unavailable")."
    case .share, .browser:
      return "The exported file is a viewing copy. Editable handwriting stays on your iPad."
    default: return "This walkthrough uses only its own saved page and handwriting."
    }
  }

  func primaryTitle() -> String {
    switch step.kind {
    case .write:
      if scenario == .missing { return "Check saving this incomplete page" }
      return record == nil ? "Save this page and my handwriting" : "Continue with this saved page"
    case .remove: return "Remove sample book, keep my saved page"
    default:
      return walkthrough.stepIndex == scenario.steps.count - 1
        ? "Finish this walkthrough" : "Next step"
    }
  }

  func mayContinue() -> Bool {
    if loading { return false }
    if case .write = step.kind {
      return (ready || scenario == .missing) && !surface.canvas.drawing.strokes.isEmpty
    }
    if case .remove = step.kind { return record != nil }
    return step.checks.isEmpty
      || ((walkthrough.checks[step.id] ?? []).count == step.checks.count
        && walkthrough.checks[step.id]?.allSatisfy { $0 } == true
        && walkthrough.answers[step.id] != nil)
  }

  func toggleCheck(_ index: Int) {
    var checked = walkthrough.checks[step.id] ?? Array(repeating: false, count: step.checks.count)
    checked[index].toggle()
    walkthrough.checks[step.id] = checked
    persistWalkthrough()
    checkControls[index].setImage(
      UIImage(systemName: checked[index] ? "checkmark.square.fill" : "square"), for: .normal)
    primary.isEnabled = mayContinue()
  }

  func chooseAnswer(_ answer: String) {
    walkthrough.answers[step.id] = answer
    persistWalkthrough()
    for (control, option) in answerControls {
      control.setImage(
        UIImage(systemName: answer == option ? "largecircle.fill.circle" : "circle"), for: .normal)
    }
    primary.isEnabled = mayContinue()
  }

  func textViewDidChange(_ textView: UITextView) {
    walkthrough.comments[step.id] = textView.text
    persistWalkthrough()
  }

  func persistWalkthrough() {
    do { try store.writeWalkthrough(walkthrough) } catch {
      status.text = "Could not save your answers: \(error.localizedDescription)"
    }
  }

  func advance() {
    if walkthrough.stepIndex == scenario.steps.count - 1 {
      walkthrough.finished = true
    } else {
      walkthrough.stepIndex += 1
    }
    persistWalkthrough()
    renderStep()
  }

  func runInitial() async {
    if automatic {
      stack.addArrangedSubview(label("Preparing local example pages…", .title2))
      stack.addArrangedSubview(surface)
      var failures: [String] = []
      var captured: [String] = []
      var missingResourceError = ""
      for item in Scenario.allCases where item != .missing {
        do {
          scenario = item
          try store.reset()
          try await loadScenario()
          surface.canvas.drawing = syntheticInk()
          try saveInk()
          try await capture()
          try removeSource()
          captured.append(item.rawValue)
        } catch { failures.append("\(item.rawValue): \(error.localizedDescription)") }
      }
      scenario = .missing
      do {
        try store.reset()
        try await loadScenario()
        surface.canvas.drawing = syntheticInk()
        try await capture()
        failures.append("missing: incomplete page was unexpectedly saved")
      } catch {
        missingResourceError = String(describing: error)
        status.text = "Expected readiness failure: \(error.localizedDescription)"
      }
      let output: [String: Any] = [
        "os": UIDevice.current.systemVersion, "syntheticInkOnly": true, "failures": failures,
        "capturedWalkthroughs": captured,
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
    } else if ProcessInfo.processInfo.arguments.contains("--walkthrough-home") {
      showHome()
    } else {
      let argument = ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--scenario=") }
      let selected =
        argument.map { String($0.dropFirst(11)) }
        ?? (try? String(contentsOf: activeURL, encoding: .utf8))
      if let selected, let item = Scenario(rawValue: selected) { start(item) } else { showHome() }
    }
  }

  func start(_ item: Scenario) {
    guard !loading else { return }
    showingHome = false
    Task {
      scenario = item
      clearScreen()
      stack.addArrangedSubview(label("Opening \(item.title.lowercased())…", .title2))
      stack.addArrangedSubview(surface)
      do {
        try FileManager.default.createDirectory(
          at: ScratchStore.root, withIntermediateDirectories: true)
        try Data(item.rawValue.utf8).write(to: activeURL, options: .atomic)
        try await loadScenario()
        #if targetEnvironment(simulator)
          if let argument = ProcessInfo.processInfo.arguments.first(where: {
            $0.hasPrefix("--inspect-step=")
          }),
            let index = Int(argument.dropFirst(15)), scenario.steps.indices.contains(index)
          {
            walkthrough.stepIndex = index
            walkthrough.finished = false
          }
        #endif
        renderStep()
        #if targetEnvironment(simulator)
          if scenario == .replacement
            && ProcessInfo.processInfo.arguments.contains("--inspect-comparison")
          {
            inspectReplacement()
          }
        #endif
      } catch { showFailure(error) }
    }
  }

  func loadScenario() async throws {
    loading = true
    defer { loading = false }
    ready = false
    record = nil
    writing = false
    setWriting()
    surface.removeWeb()
    surface.background.image = nil
    surface.scroll.setZoomScale(surface.fit, animated: false)
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
    walkthrough = try store.readWalkthrough()
    setWriting()
    if var existing = record {
      if !existing.reopenedLaunchIDs.contains(launchID) {
        existing.reopenedLaunchIDs.append(launchID)
        record = existing
        try store.writeRecord(existing)
      }
      ready = true
      details = existing.geometry
      showCandidate()
      return
    }
    if !store.hasSource {
      try FileManager.default.createDirectory(at: store.source, withIntermediateDirectories: true)
      if scenario.fixture == .pdf {
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
    if scenario.fixture == .pdf {
      let data = try Data(contentsOf: store.source.appending(path: "original.pdf"))
      surface.show(try pdfImage(data, size: surface.page.bounds.size))
      details = [
        "quote": "A useful observation", "href": "original.pdf#page=1",
        "prefix": "Original self-authored PDF",
        "suffix": "A small note can bring an old idea back into focus.",
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
      let mode =
        scenario.fixture == .missing
        ? "missing" : scenario.fixture == .columns ? "columns" : "scroll"
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
      let offset = (details[scenario.fixture == .columns ? "scrollX" : "scrollY"] as? Double) ?? 0
      guard offset > 0 else {
        throw ExperimentFailure.message("Fixture did not reach its required nonzero offset.")
      }
    }
    ready = scenario != .missing
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
        "This page was not saved because its required picture is missing. Your handwriting is still saved on the iPad."
      )
    }
    guard !surface.canvas.drawing.strokes.isEmpty else {
      throw ExperimentFailure.message("Write at least one mark before saving this page.")
    }
    primary.isEnabled = false
    status.text = "Saving this page and your editable handwriting…"
    let started = Date()
    let memoryBefore = processLifetimePeakRSS()
    let image: UIImage
    var fixed: Data?
    var fixedError: String?
    if scenario.fixture == .pdf {
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
      throw ExperimentFailure.message(
        "The page image is unavailable or exceeds this experiment's size limit.")
    }
    try store.write(png, "background.png")
    if let fixed { try store.write(fixed, "background.pdf") }
    if fixed == nil && fixedError == nil { fixedError = "No PDF copy was returned." }
    let sourceFile =
      scenario.fixture == .pdf
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
    if scenario.fixture == .pdf {
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
    if scenario == .maintenance {
      try store.write(Data("Saved locally; not sent to a server".utf8), "local-unsent-marker.txt")
    }
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
  }

  func showCandidate() {
    guard let record else { return }
    do {
      let image: UIImage
      let scale: Int
      if case .view(let pdf, let zoom) = step.kind {
        scale = zoom
        if pdf {
          if let failure = record.fixedPageError { throw ExperimentFailure.message(failure) }
          image = try pdfImage(
            Data(contentsOf: store.retained.appending(path: "background.pdf")),
            size: surface.page.bounds.size, scale: CGFloat(max(2, zoom)))
        } else {
          guard
            let saved = UIImage(
              contentsOfFile: store.retained.appending(path: "background.png").path)
          else {
            throw ExperimentFailure.message("The saved page image is missing.")
          }
          image = saved
        }
      } else {
        scale = 1
        guard
          let saved = UIImage(contentsOfFile: store.retained.appending(path: "background.png").path)
        else {
          throw ExperimentFailure.message("The saved page image is missing.")
        }
        image = saved
      }
      surface.show(image)
      surface.layoutIfNeeded()
      surface.scroll.setZoomScale(surface.fit * CGFloat(scale), animated: false)
      if scale > 1 {
        let x = CGFloat(record.geometry["wordX"] ?? 180) * surface.scroll.zoomScale - 100
        let y = CGFloat(record.geometry["wordY"] ?? 120) * surface.scroll.zoomScale - 80
        surface.scroll.setContentOffset(
          CGPoint(
            x: max(0, min(x, surface.scroll.contentSize.width - surface.bounds.width)),
            y: max(0, min(y, surface.scroll.contentSize.height - surface.bounds.height))),
          animated: false)
      }
    } catch {
      status.text =
        "This saved view could not open: \(error.localizedDescription). Choose the problem answer below; your other saved files and ink are kept."
    }
  }

  func toggleWriting() {
    writing.toggle()
    setWriting()
  }
  func setWriting() {
    writeButton.setTitle(writing ? "Turn writing off" : "Turn writing on", for: .normal)
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
      primary.isEnabled = mayContinue()
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
    guard mayContinue() else { return }
    Task {
      do {
        switch step.kind {
        case .write:
          writing = false
          setWriting()
          if scenario == .missing {
            do {
              try await capture()
              walkthrough.lastMessage =
                "Unexpected result: the incomplete page was saved. Report this as a problem."
            } catch {
              walkthrough.lastMessage = error.localizedDescription
            }
          } else if record == nil {
            try await capture()
          }
        case .remove:
          try removeSource()
        default: break
        }
        advance()
      } catch { showFailure(error) }
    }
  }

  func showFailure(_ error: Error) {
    let explanation =
      (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String
      ?? error.localizedDescription
    let alert = UIAlertController(
      title: "This step could not finish",
      message:
        "\(explanation)\n\nYour saved handwriting has not been deleted. You can go back or record this problem.",
      preferredStyle: .alert)
    alert.addAction(
      UIAlertAction(title: "Return to walkthroughs", style: .cancel) { [weak self] _ in
        self?.showHome()
      })
    alert.addAction(
      UIAlertAction(title: "Record problem and finish", style: .default) { [weak self] _ in
        guard let self else { return }
        walkthrough.answers["save-problem"] = explanation
        walkthrough.finished = true
        persistWalkthrough()
        renderStep()
      })
    present(alert, animated: true)
  }

  func confirmReset() {
    let alert = UIAlertController(
      title: "Start this walkthrough again?",
      message:
        "This deletes only this walkthrough's sample page, ink and answers. Every other walkthrough is kept.",
      preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    alert.addAction(
      UIAlertAction(title: "Delete this sample and restart", style: .destructive) { [weak self] _ in
        guard let self else { return }
        do {
          try store.reset()
          start(scenario)
        } catch { showFailure(error) }
      })
    present(alert, animated: true)
  }

  func exportPreview() throws {
    guard let record else {
      throw ExperimentFailure.message("Save this page before sharing a preview.")
    }
    let rect = surface.page.bounds
    let ink = surface.canvas.drawing.image(from: rect, scale: 2)
    guard let inkData = ink.pngData() else {
      throw ExperimentFailure.message("Ink preview could not be rendered.")
    }
    try store.write(inkData, "ink-preview.png")
    let background = try Data(contentsOf: store.retained.appending(path: "background.png"))
    var fixedHTML =
      "<p>PDF copy unavailable: \(htmlEscape(record.fixedPageError ?? "not available"))</p>"
    if record.fixedPageError == nil {
      let fixed = try pdfImage(
        Data(contentsOf: store.retained.appending(path: "background.pdf")), size: rect.size)
      if let data = fixed.pngData() {
        fixedHTML = figure(
          data, inkData, title: "PDF copy, shown as a 2x image for this preview")
      }
    }
    let html = """
      <!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
      <title>Original annotation context: \(scenario.rawValue)</title>
      <style>body{font:18px system-ui;max-width:850px;margin:24px auto;padding:0 16px;background:#f3f3f1;color:#222}figure{margin:16px 0;overflow:auto}section{position:relative;width:640px;height:480px;background:white}img{position:absolute;width:640px;height:480px;inset:0}button{padding:10px;margin:8px}pre{white-space:pre-wrap}</style>
      <h1>Can you still read the original note?</h1><p>PROTOTYPE: saved source-replacement context, not normal EPUB reflow or BookOrbit sync. This single file contains its images and current ink preview. No font, original book, WebArchive, or PencilKit decoder is needed.</p>
      <p>\(htmlEscape(scenario.title)). iPadOS/simulator \(htmlEscape(record.os)). Ink revision \(record.inkRevision). Source absent at export: \(!store.hasSource).</p>
        <p>Input evidence: \(htmlEscape(record.inputEvidence ?? "Not recorded; do not treat this as physical Pencil evidence"))</p>
      <p>Compare both examples. Check the text, illustration, margins and translucent ink. Use browser zoom or horizontal scrolling to inspect enlarged display. The iPad can show the PDF copy with more detail than this 2x preview image.</p>
      \(figure(background, inkData, title: "Page image with current ink"))\(fixedHTML)
      <h2>Original sentence</h2><p>\(htmlEscape(record.context["quote"] ?? ""))</p><p>Before: \(htmlEscape(record.context["prefix"] ?? ""))<br>After: \(htmlEscape(record.context["suffix"] ?? ""))</p><p>Original anchor: \(htmlEscape(record.context["href"] ?? "")). This note has not been moved to a revised edition.</p>
      <h2>Walkthrough answers</h2>\(scenario.steps.filter { walkthrough.answers[$0.id] != nil }.map { "<p><strong>\(htmlEscape($0.question))</strong><br>\(htmlEscape(walkthrough.answers[$0.id] ?? ""))<br>\(htmlEscape(walkthrough.comments[$0.id] ?? ""))</p>" }.joined())<p>Record the result for each named browser in the iPad walkthrough. Viewing this file does not answer the questions automatically.</p></html>
      """
    try store.write(Data(html.utf8), "preview.html")
  }

  func figure(_ background: Data, _ ink: Data, title: String) -> String {
    "<h2>\(title)</h2><figure><section><img alt=\"Original book excerpt\" src=\"data:image/png;base64,\(background.base64EncodedString())\"><img alt=\"Current handwriting, viewing only\" src=\"data:image/png;base64,\(ink.base64EncodedString())\"></section></figure>"
  }

  func sharePreview() {
    do {
      try exportPreview()
      walkthrough.actions["shared"] = true
      persistWalkthrough()
      let controller = UIActivityViewController(
        activityItems: [store.retained.appending(path: "preview.html")], applicationActivities: nil)
      controller.popoverPresentationController?.sourceView = view
      controller.popoverPresentationController?.sourceRect = CGRect(
        x: view.bounds.midX, y: view.bounds.maxY - 50, width: 1, height: 1)
      present(controller, animated: true)
    } catch { showFailure(error) }
  }

  func inspectReplacement() {
    guard let record else { return }
    let comparison = OriginalContextComparisonController(store: store, record: record)
    comparison.onReady = { [weak self] in
      self?.walkthrough.actions["visual-comparison-opened"] = true
      self?.persistWalkthrough()
    }
    comparison.modalPresentationStyle = .fullScreen
    present(comparison, animated: true)
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

@MainActor
final class OriginalContextComparisonController: UIViewController, WKNavigationDelegate {
  let store: ScratchStore
  let record: ArchiveRecord
  let original = CaptureSurface()
  let revised = CaptureSurface()
  let pages = UIStackView()
  let message = UILabel()
  var onReady: (() -> Void)?
  var continuation: CheckedContinuation<Void, Error>?
  var started = false

  init(store: ScratchStore, record: ArchiveRecord) {
    self.store = store
    self.record = record
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError() }

  func label(_ text: String, _ style: UIFont.TextStyle = .body) -> UILabel {
    let label = UILabel()
    label.text = text
    label.numberOfLines = 0
    label.font = .preferredFont(forTextStyle: style)
    return label
  }

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
    stack.spacing = 20
    stack.translatesAutoresizingMaskIntoConstraints = false
    scroll.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 24),
      stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
      stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 24),
      stack.trailingAnchor.constraint(
        equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -24),
    ])
    stack.addArrangedSubview(label("Your original note beside a revised page", .title1))
    stack.addArrangedSubview(
      label(
        "Find useful and your ink on the original. Find revised on the new sample. Your old ink should stay with the original words. Pinch either page to enlarge it, then drag with a finger to look around."
      ))
    pages.axis = .horizontal
    pages.distribution = .fillEqually
    pages.spacing = 20
    let originalWords = record.context["quote"] ?? ""
    for (title, surface, words) in [
      ("Original page with your handwriting", original, originalWords),
      (
        "Revised sample page", revised,
        originalWords.replacingOccurrences(of: "useful", with: "revised")
      ),
    ] {
      let panel = UIStackView()
      panel.axis = .vertical
      panel.spacing = 12
      panel.addArrangedSubview(label(title, .headline))
      surface.heightAnchor.constraint(equalToConstant: 380).isActive = true
      surface.canvas.isUserInteractionEnabled = false
      panel.addArrangedSubview(surface)
      panel.addArrangedSubview(label(words, .callout))
      pages.addArrangedSubview(panel)
    }
    stack.addArrangedSubview(pages)
    message.numberOfLines = 0
    message.font = .preferredFont(forTextStyle: .callout)
    message.text = "Opening the revised sample. Your saved original page and ink are kept."
    stack.addArrangedSubview(message)
    let close = UIButton(type: .system)
    close.configuration = .filled()
    close.setTitle("Back to the walkthrough questions", for: .normal)
    close.addAction(
      UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .touchUpInside)
    stack.addArrangedSubview(close)
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    pages.axis = view.bounds.width >= 800 ? .horizontal : .vertical
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    guard !started else { return }
    started = true
    Task {
      do { try await loadComparison() } catch {
        message.text =
          "The revised page could not open: \(error.localizedDescription). Your original note is kept. Return and report that you could not compare the pages."
      }
    }
  }

  func loadComparison() async throws {
    let background = try Data(contentsOf: store.retained.appending(path: "background.png"))
    guard let image = UIImage(data: background) else {
      throw ExperimentFailure.message("The original saved page image could not open.")
    }
    let ink = try Data(contentsOf: store.retained.appending(path: "ink.drawing"))
    original.show(image)
    original.canvas.drawing = try PKDrawing(data: ink)
    view.layoutIfNeeded()
    for surface in [original, revised] {
      surface.layoutIfNeeded()
      surface.scroll.setZoomScale(surface.fit, animated: false)
    }
    let working = store.folder.appending(path: "revised-sample")
    if FileManager.default.fileExists(atPath: working.path) {
      try FileManager.default.removeItem(at: working)
    }
    if store.hasSource {
      try FileManager.default.copyItem(at: store.source, to: working)
    } else {
      guard let seed = Bundle.main.url(forResource: "Fixtures", withExtension: nil) else {
        throw ExperimentFailure.message("The revised sample resources are unavailable.")
      }
      try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
      try FileManager.default.copyItem(
        at: seed.appending(path: "EPUB"), to: working.appending(path: "EPUB"))
    }
    let chapter = working.appending(path: "EPUB/OEBPS/chapter.xhtml")
    let text = try String(contentsOf: chapter, encoding: .utf8)
    guard text.contains(">useful</span>") else {
      throw ExperimentFailure.message("The expected sample word was not found.")
    }
    try text.replacingOccurrences(of: ">useful</span>", with: ">revised</span>").write(
      to: chapter, atomically: true, encoding: .utf8)
    let web = revised.attachWeb()
    web.navigationDelegate = self
    try await withCheckedThrowingContinuation { callback in
      continuation = callback
      web.loadFileURL(chapter, allowingReadAccessTo: working)
    }
    let result = try await web.callAsyncJavaScript(
      "return await prepareFixture('scroll')", arguments: [:], in: nil, contentWorld: .page)
    guard let geometry = result as? [String: Any], let quote = geometry["quote"] as? String,
      quote.contains("revised"), !quote.contains("useful")
    else {
      throw ExperimentFailure.message("The revised page did not reach its expected sentence.")
    }
    let configuration = WKSnapshotConfiguration()
    configuration.rect = web.bounds
    configuration.snapshotWidth = 640
    let snapshot = try await web.takeSnapshot(configuration: configuration)
    if let png = snapshot.pngData() { try store.write(png, "revised-background.png") }
    try store.write(Data(quote.utf8), "revised-quote.txt")
    let evidence: [String: Any] = [
      "originalBackgroundSHA256": digest(background), "originalInkSHA256": digest(ink),
      "originalQuote": record.context["quote"] ?? "", "revisedQuote": quote,
      "originalAnchor": record.context["href"] ?? "",
      "revisedChapterSHA256": digest(try Data(contentsOf: chapter)),
      "oldInkMovedToRevisedPage": false, "geometry": geometry,
      "scope":
        "Local revised sample rendered beside retained original page and separate original ink; no full-book import or note migration",
    ]
    try store.write(
      JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]),
      "visual-comparison.json")
    message.text =
      "The original page still has your ink. The revised sample has changed words and no old ink. This test keeps the original context; it does not move your note."
    onReady?()
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    continuation?.resume()
    continuation = nil
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    continuation?.resume(throwing: error)
    continuation = nil
  }

  func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) {
    self.webView(webView, didFail: navigation, withError: error)
  }
}
