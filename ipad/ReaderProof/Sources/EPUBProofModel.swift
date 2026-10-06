import Foundation
import Observation
import WebKit

@MainActor @Observable
final class EPUBProofModel: NSObject, WKNavigationDelegate, WKScriptMessageHandlerWithReply {
  let api: BookOrbitAPI
  let bookID: Int
  let file: BookDetailFile
  let webView: WKWebView
  private let assets: EPUBAssetHandler
  var anchor = ""
  private(set) var resolvedText = ""
  private(set) var roundTripAnchor = ""
  private(set) var error: String?
  private(set) var isReady = false
  private(set) var isResolving = false
  private(set) var isPlainChapter = false
  private(set) var isSaving = false
  private(set) var status = ""
  private var initialCFI: String?
  private var selectedPosition: PassagePosition?
  private var saveTask: Task<Void, Never>?
  private var info: EpubBookInfo?
  private var folder: URL?
  private var entryURL: URL?
  private var paths: Set<String> = []
  private var sizes: [String: Int] = [:]
  private var resourceTasks: [UUID: Task<Void, Never>] = [:]
  private var isClosed = false

  private struct PassagePosition {
    let cfi: String
    let percentage: Double
  }

  init(api: BookOrbitAPI, bookID: Int, file: BookDetailFile) {
    self.api = api
    self.bookID = bookID
    self.file = file
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    let assets = EPUBAssetHandler()
    self.assets = assets
    configuration.setURLSchemeHandler(assets, forURLScheme: "bookorbit-reader")
    webView = WKWebView(frame: .zero, configuration: configuration)
    super.init()
    webView.navigationDelegate = self
    webView.configuration.userContentController.addScriptMessageHandler(
      self, contentWorld: .page, name: "resource")
  }

  func load() async {
    do {
      let progress: FileReadingProgress = try await api.send("books/files/\(file.id)/progress")
      if let cfi = progress.cfi, cfi.count > 4096 { throw ConnectionError.invalidResponse }
      initialCFI = progress.cfi
      let info: EpubBookInfo = try await api.send(
        "epub/\(bookID)/info", query: [URLQueryItem(name: "fileId", value: String(file.id))])
      try Task.checkCancellation()
      guard !isClosed else { return }
      self.info = info
      sizes = Dictionary(
        info.manifest.map { ($0.href, $0.size) }, uniquingKeysWith: { first, _ in first })
      paths = Set(
        info.manifest.map(\.href) + (info.optionalFiles ?? []) + [
          "META-INF/container.xml", info.containerPath,
        ])
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "bookorbit-epub-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      folder = root
      for name in ["EPUBProof", "foliate"] {
        guard let source = Bundle.main.url(forResource: name, withExtension: nil) else {
          throw ConnectionError.invalidResponse
        }
        try FileManager.default.copyItem(
          at: source, to: root.appendingPathComponent(name, isDirectory: true))
      }
      assets.root = root
      let entry = assets.origin.appendingPathComponent("EPUBProof/index.html")
      entryURL = entry
      webView.load(URLRequest(url: entry))
    } catch is CancellationError {
      close()
    } catch {
      self.error = error.localizedDescription
    }
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    Task {
      do {
        guard !isClosed, let info else { return }
        let value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(info))
        _ = try await webView.callAsyncJavaScript(
          "await import('./reader.js'); return await window.openPublication(info, cfi)",
          arguments: ["info": value, "cfi": initialCFI as Any? ?? NSNull()], in: nil,
          contentWorld: .page)
        if !isClosed { isReady = true }
      } catch {
        if !isClosed {
          let detail = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String
          self.error =
            detail.map { "Reader initialization failed: \(String($0.prefix(240)))" }
            ?? error.localizedDescription
        }
      }
    }
  }

  func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: any Error
  ) {
    if !isClosed { self.error = error.localizedDescription }
  }

  func webView(
    _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
  ) {
    let url = navigationAction.request.url
    let allowed =
      url == entryURL
      || (navigationAction.targetFrame?.isMainFrame == false && url?.scheme == "blob")
    decisionHandler(allowed ? .allow : .cancel)
  }

  func userContentController(
    _ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
    replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
  ) {
    guard !isClosed, message.frameInfo.isMainFrame, message.frameInfo.request.url == entryURL,
      let path = message.body as? String, paths.contains(path), path.count <= 4096,
      !path.hasPrefix("/"), !path.contains("\\"), !path.split(separator: "/").contains(".."),
      resourceTasks.count < 4
    else {
      replyHandler(nil, "This resource is unavailable.")
      return
    }
    let id = UUID()
    resourceTasks[id] = Task {
      defer { resourceTasks[id] = nil }
      do {
        let data = try await api.epubResource(
          bookID: bookID, fileID: file.id, path: path, expectedSize: sizes[path])
        try Task.checkCancellation()
        guard !isClosed else { throw CancellationError() }
        replyHandler(data.base64EncodedString(), nil)
      } catch {
        replyHandler(nil, error.localizedDescription)
      }
    }
  }

  func resolvePassage() {
    guard isReady, !isResolving, !isSaving, !isPlainChapter, anchor.count <= 4096 else { return }
    isResolving = true
    resolvedText = ""
    roundTripAnchor = ""
    selectedPosition = nil
    status = ""
    error = nil
    webView.becomeFirstResponder()
    Task {
      defer { isResolving = false }
      do {
        let result = try await webView.callAsyncJavaScript(
          "return await window.resolvePassage(cfi)", arguments: ["cfi": anchor], in: nil,
          contentWorld: .page)
        guard !isClosed, let result = result as? [String: Any],
          let text = result["text"] as? String,
          let cfi = result["cfi"] as? String, let percentage = result["percentage"] as? Double,
          percentage.isFinite, (0...100).contains(percentage), cfi.count <= 4096
        else {
          throw ConnectionError.invalidResponse
        }
        resolvedText = text
        roundTripAnchor = cfi
        selectedPosition = PassagePosition(cfi: cfi, percentage: percentage)
      } catch {
        if !isClosed { self.error = error.localizedDescription }
      }
    }
  }

  func inspectPlainChapter() {
    guard isReady, !isResolving, !isSaving, !isPlainChapter, !isClosed else { return }
    isResolving = true
    error = nil
    Task {
      defer { isResolving = false }
      do {
        _ = try await webView.callAsyncJavaScript(
          "return await window.openPlainChapter()", arguments: [:], in: nil,
          contentWorld: .page)
        if !isClosed { isPlainChapter = true }
      } catch {
        if !isClosed { self.error = error.localizedDescription }
      }
    }
  }

  func savePassagePosition() {
    guard let position = selectedPosition, !isSaving, !isResolving, !isPlainChapter, !isClosed
    else {
      return
    }
    isSaving = true
    status = "Saving position…"
    error = nil
    saveTask = Task {
      defer {
        isSaving = false
        saveTask = nil
      }
      do {
        var payload = SaveFileProgressPayload(percentage: position.percentage)
        payload.source = "text"
        payload.cfi = position.cfi
        try Task.checkCancellation()
        guard !isClosed else { return }
        try await api.sendEmpty(
          "books/files/\(file.id)/progress", body: JSONEncoder().encode(payload))
        if !isClosed { status = "Position saved" }
      } catch {
        if !isClosed {
          status = "Position could not be saved."
          self.error = error.localizedDescription
        }
      }
    }
  }

  func close() {
    isClosed = true
    saveTask?.cancel()
    webView.stopLoading()
    webView.navigationDelegate = nil
    webView.configuration.userContentController.removeScriptMessageHandler(
      forName: "resource", contentWorld: .page)
    for task in resourceTasks.values { task.cancel() }
    resourceTasks.removeAll()
    assets.root = nil
    if let folder { try? FileManager.default.removeItem(at: folder) }
    folder = nil
  }
}
