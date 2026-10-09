import Foundation
import OSLog
import Observation
import UIKit
import WebKit

private struct EPUBProgressJournal: Codable {
  let cfi: String
  let percentage: Double
}

struct EPUBReadingLocation {
  let cfi: String
  let percentage: Double
  let chapterIndex: Int
  let rightToLeft: Bool
  let page: Int?
  let pageTotal: Int?
  let remainingMinutes: Int?
  let chapterLabel: String
  let locationNumber: Int?
  let locationTotal: Int?
}

struct EPUBSearchResult: Identifiable, Codable {
  let id: String
  let text: String
}

struct EPUBSearchPage: Codable {
  let items: [EPUBSearchResult]
  let nextChapter: Int
  let complete: Bool
}

@MainActor @Observable
final class EPUBReaderModel: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
  private static let fixtureLogger = Logger(
    subsystem: "com.mooneeb.bookorbit.private", category: "epub.fixture_selection")
  let api: BookOrbitAPI
  let bookID: Int
  let file: BookDetailFile
  private let continuation: BookContinuationTarget?
  let webView: WKWebView
  let position: NativeFilePositionModel
  let preferences: EPUBPreferencesModel
  private let resources: EPUBPublicationResources
  private let fontResources: EPUBFontResources
  private(set) var fontFailure: String?
  private(set) var info: EpubBookInfo?
  private var deliveredOutline: DeliveredEbookOutline?
  private(set) var location: EPUBReadingLocation?
  private(set) var narrationLocation: EPUBReadingLocation?
  var visibleLocation: EPUBReadingLocation? { narrationLocation ?? location }
  private(set) var selectionCFI: String?
  private(set) var selectionText = ""
  private var selectionLanguage: String?
  private(set) var publicationID = UUID()
  private(set) var isReady = false
  private(set) var isLoading = false
  private(set) var isNavigating = false
  private(set) var isPositionResetting = false
  private(set) var isSaving = false
  private(set) var isSearching = false
  private(set) var results: [EPUBSearchResult] = []
  private(set) var searchComplete = false
  private(set) var searchedChapters = 0
  private(set) var searchQuery = ""
  private(set) var error: String?
  private(set) var status: String?
  @ObservationIgnored var prepareTurn: (@MainActor (UIImage) -> Void)?
  @ObservationIgnored var commitTurn: (@MainActor (Bool, ReaderTurnAnimation) async -> Void)?
  @ObservationIgnored var cancelTurn: (@MainActor () -> Void)?
  @ObservationIgnored var openPassageAnnotation: (@MainActor (Int) -> Void)?
  @ObservationIgnored var commitPencilHighlight: (@MainActor (EPUBSelectedPassage, UUID) -> Void)?
  private var navigationWait: CheckedContinuation<Void, any Error>?
  private var expectedNavigation: WKNavigation?
  private var navigationTimeout: Task<Void, Never>?
  private var generation: UUID?
  private var pendingProgress: SaveFileProgressPayload?
  private var progressKey: String?
  private var saveTask: Task<Void, Never>?
  private var sessionTask: Task<Void, Never>?
  private var isClosed = false
  private var reduceMotion = false
  private(set) var annotationWriting = false
  private(set) var isPencilMarking = false
  private var revealingAnnotation = false
  private var annotationRevealOrigin: EPUBReadingLocation?
  private let openedAt = Date()

  init(
    api: BookOrbitAPI, bookID: Int, file: BookDetailFile,
    continuation: BookContinuationTarget? = nil
  ) {
    self.api = api
    self.bookID = bookID
    self.file = file
    self.continuation = continuation
    position = NativeFilePositionModel(
      api: api, fileID: file.id,
      sourceIdentity: file.absolutePath + ":" + String(file.sizeBytes ?? -1))
    preferences = EPUBPreferencesModel(api: api, fileID: file.id)
    let resources = EPUBPublicationResources(api: api, bookID: bookID, fileID: file.id)
    self.resources = resources
    let fontResources = EPUBFontResources(api: api)
    self.fontResources = fontResources
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.setURLSchemeHandler(resources, forURLScheme: "bookorbit-publication")
    configuration.setURLSchemeHandler(fontResources, forURLScheme: "bookorbit-font")
    webView = WKWebView(frame: .zero, configuration: configuration)
    super.init()
    webView.isOpaque = false
    webView.backgroundColor = .systemBackground
    webView.accessibilityIdentifier = "epubReaderContent"
    webView.navigationDelegate = self
    configuration.userContentController.addScriptMessageHandler(
      resources, contentWorld: .page, name: "resource")
    configuration.userContentController.add(self, name: "location")
    configuration.userContentController.add(self, name: "selection")
    configuration.userContentController.add(self, name: "passageAnnotation")
    configuration.userContentController.add(self, name: "pencilRelease")
    configuration.userContentController.add(self, name: "pencilMarking")
    configuration.userContentController.add(self, name: "readerError")
    preferences.validateFont = { [weak self] requested in
      guard let self, self.isReady, !self.isClosed else { throw EPUBFontError.loadFailed }
      try await self.prepareFontSelection(requested)
    }
  }

  var positionText: String {
    guard let location = visibleLocation, chapterCount > 0 else { return "" }
    let chapter = "Chapter \(location.chapterIndex + 1) of \(chapterCount)"
    switch preferences.value.settings.footerDisplayMode {
    case 1:
      if let minutes = location.remainingMinutes {
        return
          "Estimated \(minutes) minutes remaining, session \(Int(Date().timeIntervalSince(openedAt) / 60)) minutes"
      }
      return "\(Int(location.percentage)) percent read"
    case 2:
      return location.chapterLabel.isEmpty
        ? chapter : "\(location.chapterLabel), \(chapter.lowercased())"
    default:
      if let page = location.page, let total = location.pageTotal {
        return "Page \(page) of \(total) in chapter, \(Int(location.percentage)) percent"
      }
      return "\(chapter), \(Int(location.percentage)) percent"
    }
  }

  var rightToLeft: Bool { visibleLocation?.rightToLeft == true }
  var isContinuous: Bool {
    preferences.supportsContinuous && preferences.value.settings.flow == "scrolled"
  }
  var chapterCount: Int { deliveredOutline?.sectionCount ?? info?.spine.count ?? 0 }
  var contents: [EpubTocItem] {
    if let deliveredOutline { return deliveredOutline.toc }
    return info?.toc.map { [$0] } ?? []
  }
  var canNavigate: Bool {
    isReady && !isNavigating && !isSaving && !isSearching && pendingProgress == nil
      && !position.conflict.isBlocked && !isPositionResetting && !isClosed
  }
  var canSave: Bool {
    isReady && location != nil && !isNavigating && !isSaving && !position.conflict.isBlocked
      && !isPositionResetting && !isClosed
  }
  var hasPendingSave: Bool { pendingProgress != nil }
  var canClose: Bool { !isSaving && !isNavigating && !isSearching }

  func selectedPassage(language: String?) -> EPUBSelectedPassage? {
    guard isReady, !isClosed, let selectionCFI, !selectionText.isEmpty else { return nil }
    return .init(
      publicationID: publicationID, cfi: selectionCFI, text: selectionText,
      language: selectionLanguage ?? language ?? "en")
  }

  func load() async {
    guard !isLoading, !isReady, !isClosed else { return }
    isLoading = true
    error = nil
    status = nil
    defer { isLoading = false }
    do {
      webView.stopLoading()
      resources.reset()
      fontResources.reset()
      fontFailure = nil
      let session = try await api.authenticatedSessionGeneration()
      generation = session
      let namespace = try await api.storageNamespace()
      progressKey = "bookorbit.epub-progress.\(namespace).file.\(file.id)"
      await preferences.load()
      guard preferences.hasLoaded else { throw ConnectionError.invalidResponse }
      let progress: FileReadingProgress = try await api.boundedJSON(
        "books/files/\(file.id)/progress", session: session)
      guard progress.percentage.isFinite, (0...100).contains(progress.percentage),
        progress.cfi.map({ $0.hasPrefix("epubcfi(") && $0.utf16.count <= 2000 }) ?? true
      else { throw ConnectionError.invalidResponse }
      try await position.accept(progress, session: session)
      if let continuation {
        guard continuation.fileId == file.id, continuation.cfi == progress.cfi,
          continuation.cfi == position.resumeCFI
        else {
          throw NativeContinuationError(
            message:
              "The destination reading position changed. Close this reader and save the source again before continuing."
          )
        }
      }
      if let progressKey, let data = UserDefaults.standard.data(forKey: progressKey),
        data.count <= 8192,
        let journal = try? JSONDecoder().decode(EPUBProgressJournal.self, from: data),
        journal.cfi.hasPrefix("epubcfi("), journal.cfi.utf16.count <= 2000,
        journal.percentage.isFinite, (0...100).contains(journal.percentage)
      {
        if let continuation, journal.cfi != continuation.cfi {
          throw NativeContinuationError(
            message:
              "This edition has a pending reading position on this iPad. Open it normally and confirm that save before continuing."
          )
        }
        var payload = SaveFileProgressPayload(percentage: journal.percentage)
        payload.cfi = journal.cfi
        payload.source = "text"
        pendingProgress = payload
        position.retainLocal(payload)
        if !position.conflict.isBlocked { pendingProgress = nil }
      }
      let source = try EbookPublicationSource.resolve(file)
      let url: URL
      var deliveredSize = 0
      info = nil
      deliveredOutline = nil
      switch source {
      case .epub:
        let info: EpubBookInfo = try await api.boundedJSON(
          "epub/\(bookID)/info",
          query: [URLQueryItem(name: "fileId", value: String(file.id))], byteLimit: 8 * 1024 * 1024,
          session: session)
        self.info = info
        url = try resources.prepare(info, session: session)
      case .delivered(_, let mimeType, let size, let maximumSize):
        let content = try await api.deliveredFile(
          fileID: file.id, expectedSize: size.map(Double.init), mimeType: mimeType,
          maximumSize: Int64(maximumSize), session: session)
        defer { try? FileManager.default.removeItem(at: content) }
        try Task.checkCancellation()
        guard !isClosed else { throw CancellationError() }
        let attributes = try FileManager.default.attributesOfItem(atPath: content.path)
        guard let bytes = attributes[.size] as? NSNumber,
          (1...maximumSize).contains(bytes.intValue)
        else { throw ConnectionError.fileChanged }
        deliveredSize = bytes.intValue
        url = try resources.prepareDelivered(content, size: deliveredSize, session: session)
      }
      try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
          navigationWait = continuation
          expectedNavigation = webView.load(URLRequest(url: url))
          navigationTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            self?.finishNavigation(URLError(.timedOut))
          }
          if expectedNavigation == nil { finishNavigation(ConnectionError.invalidResponse) }
        }
      } onCancel: {
        Task { @MainActor [weak self] in self?.finishNavigation(CancellationError()) }
      }
      try Task.checkCancellation()
      guard !isClosed else { return }
      var arguments: [String: Any] = [
        "cfi": position.resumeCFI as Any? ?? NSNull(),
        "settings": try renderSettings(hideCustomFont: true),
        "formatting": preferences.useFormatting,
      ]
      switch source {
      case .epub:
        arguments["info"] = try json(info)
        let value = try await webView.callAsyncJavaScript(
          "await import('./reader.js'); return await window.epubOpen(info, cfi, settings, formatting)",
          arguments: arguments, in: nil, contentWorld: .page)
        location = try decodedLocation(value)
      case .delivered(let format, _, _, _):
        arguments["format"] = format
        arguments["size"] = deliveredSize
        let raw = try await webView.callAsyncJavaScript(
          "await import('./reader.js'); return await window.epubOpenDelivered(format, size, cfi, settings, formatting)",
          arguments: arguments, in: nil, contentWorld: .page)
        guard let value = raw as? [String: Any] else {
          throw ConnectionError.invalidResponse
        }
        if let failure = value["failure"] as? String, !failure.isEmpty, failure.utf16.count <= 500 {
          throw DeliveredEbookFailure(message: failure)
        }
        guard let outline = value["outline"] else { throw ConnectionError.invalidResponse }
        let data = try JSONSerialization.data(withJSONObject: outline)
        guard data.count <= 2 * 1024 * 1024 else { throw ConnectionError.resourceTooLarge }
        let decoded = try JSONDecoder().decode(DeliveredEbookOutline.self, from: data)
        guard (1...4096).contains(decoded.sectionCount) else {
          throw ConnectionError.invalidResponse
        }
        deliveredOutline = decoded
        location = try decodedLocation(value["location"])
      }
      try await restoreCustomTypography()
      guard !isClosed, try await api.authenticatedSessionGeneration() == session else {
        throw ConnectionError.expiredSession
      }
      isReady = true
      if position.resumeCFI == nil, let location {
        var beginning = SaveFileProgressPayload(percentage: location.percentage)
        beginning.cfi = location.cfi
        position.setBeginning(beginning)
      }
      startSessionMonitor()
      await describePositionConflict(position)
      if pendingProgress != nil && !position.conflict.isBlocked { await saveProgress() }
    } catch {
      if !isClosed {
        self.error = error.localizedDescription
        clearContent()
        resources.reset()
        fontResources.reset()
      }
    }
  }

  func turn(forward: Bool) async {
    await navigate(
      "return await window.epubTurn(forward, smooth)",
      arguments: ["forward": forward, "smooth": false], forward: forward)
  }

  func goToChapter(_ index: Int) async {
    guard (0..<chapterCount).contains(index) else { return }
    await navigate(
      "return await window.epubGo(target, smooth)", arguments: ["target": index],
      forward: index >= (visibleLocation?.chapterIndex ?? 0), programmatic: true)
  }

  func goToContentsChapter(_ index: Int) async -> Bool {
    guard (0..<chapterCount).contains(index), canNavigate else { return false }
    return await navigate(
      "return await window.epubGo(target, smooth)", arguments: ["target": index],
      forward: index >= (visibleLocation?.chapterIndex ?? 0), programmatic: true,
      preserveContentOnFailure: true)
  }

  func goToCFI(_ cfi: String) async {
    guard cfi.hasPrefix("epubcfi("), cfi.utf16.count <= 2000 else { return }
    await navigate(
      "return await window.epubGo(target, smooth)", arguments: ["target": cfi], forward: true,
      programmatic: true)
  }

  func bookmarkSessionGeneration() async throws -> UUID {
    guard isReady, !isClosed, let generation,
      try await api.authenticatedSessionGeneration() == generation
    else { throw ConnectionError.expiredSession }
    return generation
  }

  func goToBookmarkCFI(_ cfi: String) async -> EPUBPositionJumpResult {
    guard cfi.hasPrefix("epubcfi("), cfi.utf16.count <= 2000, canNavigate else { return .failed }
    let moved = await navigate(
      "return await window.epubGo(target, smooth)", arguments: ["target": cfi], forward: true,
      programmatic: true, preserveContentOnFailure: true)
    guard moved else { return .failed }
    saveTask?.cancel()
    return await saveProgress() ? .saved : .pendingSave
  }

  @discardableResult
  func goToHref(_ href: String) async -> Bool {
    guard href.utf16.count <= 4096, canNavigate else { return false }
    if let info {
      guard
        info.spine.contains(where: {
          $0.href == href.components(separatedBy: "#")[0].removingPercentEncoding
        })
      else { return false }
    } else {
      var pending: [(items: [EpubTocItem], index: Int, depth: Int)] = [(contents, 0, 0)]
      var scanned = 0
      var allowed = false
      while let frame = pending.popLast(), scanned < 4096 {
        guard frame.index < frame.items.count else { continue }
        let item = frame.items[frame.index]
        pending.append((frame.items, frame.index + 1, frame.depth))
        scanned += 1
        if item.href == href {
          allowed = true
          break
        }
        if frame.depth < 32, let children = item.children, !children.isEmpty {
          pending.append((children, 0, frame.depth + 1))
        }
      }
      guard allowed else { return false }
    }
    return await navigate(
      "return await window.epubGo(target, smooth)", arguments: ["target": href], forward: true,
      programmatic: true, preserveContentOnFailure: true)
  }

  func goToFraction(_ fraction: Double) async -> EPUBPositionJumpResult {
    guard fraction.isFinite, (0...1).contains(fraction), canNavigate else { return .failed }
    let moved = await navigate(
      "return await window.epubGoFraction(fraction, smooth)", arguments: ["fraction": fraction],
      forward: fraction * 100 >= (visibleLocation?.percentage ?? 0), programmatic: true,
      preserveContentOnFailure: true)
    guard moved else { return .failed }
    saveTask?.cancel()
    return await saveProgress() ? .saved : .pendingSave
  }

  func applyPreferences() async {
    guard isReady, !isClosed else { return }
    do {
      while isNavigating || isSearching {
        try await Task.sleep(for: .milliseconds(50))
        guard isReady, !isClosed else { return }
      }
      guard let location = visibleLocation else { return }
      let preservesNarration = narrationLocation != nil
      isNavigating = true
      defer { isNavigating = false }
      if !isSaving { saveTask?.cancel() }
      try await restoreCustomTypography()
      guard !isClosed, let generation,
        try await api.authenticatedSessionGeneration() == generation
      else { return }
      let raw = try await webView.callAsyncJavaScript(
        "return await window.epubConfigure(settings, formatting, cfi)",
        arguments: [
          "settings": try renderSettings(hideCustomFont: fontFailure != nil),
          "formatting": preferences.useFormatting, "cfi": location.cfi,
        ], in: nil, contentWorld: .page)
      guard !isClosed else { return }
      let restored = try decodedLocation(raw)
      if preservesNarration { narrationLocation = restored } else { self.location = restored }
      selectionCFI = nil
      selectionText = ""
      if !preservesNarration && annotationRevealOrigin == nil { scheduleSave() }
    } catch { self.error = error.localizedDescription }
  }

  func layoutAnchor() async -> String? {
    guard isReady, !isClosed, !isNavigating else { return visibleLocation?.cfi }
    guard isContinuous, narrationLocation == nil else { return visibleLocation?.cfi }
    do {
      let raw = try await webView.callAsyncJavaScript(
        "return window.epubLocation()", arguments: [:], in: nil, contentWorld: .page)
      guard !isClosed else { return nil }
      let current = try decodedLocation(raw)
      location = current
      return current.cfi
    } catch { return visibleLocation?.cfi }
  }

  func preserveLayout(at cfi: String) async {
    guard isReady, !isClosed, !isNavigating else { return }
    let started = Date()
    if annotationInputFixture {
      Self.fixtureLogger.info(
        "[epub.fixture_layout] [start] bookId=\(self.bookID, privacy: .public) fileId=\(self.file.id, privacy: .public) selectionPresent=\(self.selectionCFI != nil, privacy: .public) - layout preservation navigation requested"
      )
    }
    isNavigating = true
    let preservesNarration = narrationLocation?.cfi == cfi
    defer {
      isNavigating = false
      if annotationInputFixture {
        let durationMs = max(0, Int(Date().timeIntervalSince(started) * 1000))
        Self.fixtureLogger.info(
          "[epub.fixture_layout] [end] bookId=\(self.bookID, privacy: .public) fileId=\(self.file.id, privacy: .public) durationMs=\(durationMs, privacy: .public) selectionPresent=\(self.selectionCFI != nil, privacy: .public) - layout preservation navigation completed"
        )
      }
    }
    do {
      let raw = try await webView.callAsyncJavaScript(
        "return await window.epubGo(target)",
        arguments: ["target": cfi], in: nil, contentWorld: .page)
      guard !isClosed else { return }
      let restored = try decodedLocation(raw)
      if preservesNarration { narrationLocation = restored } else { location = restored }
    } catch { if !isClosed { self.error = error.localizedDescription } }
  }

  func setReduceMotion(_ enabled: Bool) { reduceMotion = enabled }

  func setAnnotationWriting(_ enabled: Bool) {
    annotationWriting = enabled
    webView.scrollView.isScrollEnabled = !isPencilMarking
    let touchTypes =
      [UITouch.TouchType.direct, .indirect, .indirectPointer] + (enabled ? [] : [.pencil])
    webView.scrollView.panGestureRecognizer.allowedTouchTypes = touchTypes.map {
      NSNumber(value: $0.rawValue)
    }
    guard isReady else { return }
    Task {
      _ = try? await webView.callAsyncJavaScript(
        "window.epubAnnotationWriting(enabled)", arguments: ["enabled": enabled], in: nil,
        contentWorld: .page)
    }
  }

  func selectFixturePassage() {
    guard annotationInputFixture, isReady else { return }
    let started = Date()
    Self.fixtureLogger.info(
      "[epub.fixture_selection] [start] bookId=\(self.bookID, privacy: .public) fileId=\(self.file.id, privacy: .public) - fixture DOM selection requested"
    )
    Task {
      do {
        let value = try await webView.callAsyncJavaScript(
          "return window.epubFixtureSelectPassage()", arguments: [:], in: nil, contentWorld: .page)
        let result = value as? [String: Any] ?? [:]
        let contents = result["contentsCount"] as? Int ?? -1
        let section = result["sectionIndex"] as? Int ?? -1
        let paragraphs = result["paragraphCount"] as? Int ?? -1
        let ranges = result["rangeCount"] as? Int ?? -1
        let collapsed = result["collapsed"] as? Bool ?? true
        let visible = result["targetVisible"] as? Bool ?? false
        let textChars = result["textChars"] as? Int ?? 0
        let cfiChars = result["cfiChars"] as? Int ?? 0
        let roundTrip = result["cfiRoundTrip"] as? Bool ?? false
        let durationMs = max(0, Int(Date().timeIntervalSince(started) * 1000))
        Self.fixtureLogger.info(
          "[epub.fixture_selection] [end] bookId=\(self.bookID, privacy: .public) fileId=\(self.file.id, privacy: .public) durationMs=\(durationMs, privacy: .public) contents=\(contents, privacy: .public) section=\(section, privacy: .public) paragraphs=\(paragraphs, privacy: .public) ranges=\(ranges, privacy: .public) collapsed=\(collapsed, privacy: .public) targetVisible=\(visible, privacy: .public) textChars=\(textChars, privacy: .public) cfiChars=\(cfiChars, privacy: .public) cfiRoundTrip=\(roundTrip, privacy: .public) - fixture DOM selection observed"
        )
      } catch {
        let durationMs = max(0, Int(Date().timeIntervalSince(started) * 1000))
        let errorClass = String(reflecting: type(of: error))
        Self.fixtureLogger.error(
          "[epub.fixture_selection] [fail] bookId=\(self.bookID, privacy: .public) fileId=\(self.file.id, privacy: .public) durationMs=\(durationMs, privacy: .public) errorCode=\((error as NSError).code, privacy: .public) errorClass=\(errorClass, privacy: .public) error=\"fixture DOM selection invocation failed\" - fixture DOM selection invocation failed"
        )
      }
    }
  }

  func releaseFixturePencil() { fixturePencil(repeating: false) }
  func repeatFixturePencil() { fixturePencil(repeating: true) }
  private func fixturePencil(repeating: Bool) {
    guard annotationInputFixture, isReady else { return }
    Task {
      _ = try? await webView.callAsyncJavaScript(
        "window.epubFixturePencilRelease(repeating)", arguments: ["repeating": repeating], in: nil,
        contentWorld: .page)
    }
  }

  func setPassageAnnotations(_ annotations: [NativeAnnotationItem]) async {
    guard isReady else { return }
    let items = annotations.compactMap { item -> [String: Any]? in
      guard let cfi = item.cfi else { return nil }
      return ["id": item.id, "cfi": cfi, "kind": item.kind]
    }
    _ = try? await webView.callAsyncJavaScript(
      "window.epubSetPassageAnnotations(items)", arguments: ["items": items], in: nil,
      contentWorld: .page)
  }

  func openAnnotationPassage(cfi: String) async {
    guard cfi.hasPrefix("epubcfi("), cfi.utf16.count <= 2000, canNavigate else { return }
    revealingAnnotation = true
    annotationRevealOrigin = location
    defer { revealingAnnotation = false }
    _ = await navigate(
      "return await window.epubGo(target, smooth)", arguments: ["target": cfi], forward: true,
      programmatic: true, preserveContentOnFailure: true, savesPosition: false)
  }

  func search(_ query: String) async {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard canNavigate, !trimmed.isEmpty, trimmed.utf16.count <= 128 else { return }
    searchQuery = trimmed
    results = []
    searchComplete = false
    searchedChapters = 0
    await searchBatch(start: true)
  }

  func searchNext() async {
    guard canNavigate, !searchQuery.isEmpty, !searchComplete else { return }
    await searchBatch(start: false)
  }

  func cancelSearch() async {
    guard isReady, !isClosed else { return }
    _ = try? await webView.callAsyncJavaScript(
      "window.epubSearchCancel()", arguments: [:], in: nil, contentWorld: .page)
    results = []
    searchQuery = ""
    searchComplete = false
  }

  private func searchBatch(start: Bool) async {
    isSearching = true
    error = nil
    defer { isSearching = false }
    do {
      let raw = try await webView.callAsyncJavaScript(
        start
          ? "return await window.epubSearchStart(query)" : "return await window.epubSearchNext()",
        arguments: ["query": searchQuery], in: nil, contentWorld: .page)
      let data = try JSONSerialization.data(withJSONObject: raw as Any)
      guard data.count <= 256 * 1024 else { throw ConnectionError.invalidResponse }
      let page = try JSONDecoder().decode(EPUBSearchPage.self, from: data)
      guard page.items.count <= 50, (0...chapterCount).contains(page.nextChapter),
        page.items.allSatisfy({
          $0.id.hasPrefix("epubcfi(") && $0.id.utf16.count <= 2000 && $0.text.utf16.count <= 500
        })
      else { throw ConnectionError.invalidResponse }
      if !isClosed {
        results = page.items
        searchComplete = page.complete
        searchedChapters = page.nextChapter
      }
    } catch { if !isClosed { self.error = error.localizedDescription } }
  }

  @discardableResult
  func saveProgress() async -> Bool {
    if annotationRevealOrigin != nil && pendingProgress == nil { return true }
    guard canSave, let generation else { return false }
    isSaving = true
    error = nil
    status = nil
    defer { isSaving = false }
    do {
      if pendingProgress == nil {
        if isContinuous && narrationLocation == nil {
          let raw = try await webView.callAsyncJavaScript(
            "return window.epubLocation()", arguments: [:], in: nil, contentWorld: .page)
          guard !isClosed else { return false }
          location = try decodedLocation(raw)
        }
        guard let location else { throw ConnectionError.invalidResponse }
        var payload = SaveFileProgressPayload(percentage: location.percentage)
        payload.source = "text"
        payload.cfi = location.cfi
        pendingProgress = payload
        if let progressKey {
          let data = try JSONEncoder().encode(
            EPUBProgressJournal(cfi: location.cfi, percentage: location.percentage))
          UserDefaults.standard.set(data, forKey: progressKey)
        }
      }
      guard let payload = pendingProgress else { throw ConnectionError.invalidResponse }
      guard let saved = await position.save(payload) else {
        self.error = position.message
        await describePositionConflict(position)
        return false
      }
      guard try await api.authenticatedSessionGeneration() == generation else {
        throw ConnectionError.expiredSession
      }
      guard !isClosed, saved.cfi == payload.cfi, saved.percentage.isFinite,
        abs(saved.percentage - payload.percentage) < 0.00001
      else { throw ConnectionError.invalidResponse }
      pendingProgress = nil
      if let progressKey { UserDefaults.standard.removeObject(forKey: progressKey) }
      status =
        position.hasPendingSync ? "Reading position saved on this iPad." : "Reading position saved."
      return true
    } catch {
      if !isClosed {
        self.error =
          "The reading position could not be confirmed. Retry Save. \(error.localizedDescription)"
      }
      return false
    }
  }

  func refreshPosition() async {
    guard !isClosed, !isPositionResetting, isReady, !isNavigating, !isSaving else { return }
    let readingLocation = annotationRevealOrigin ?? location
    var local = SaveFileProgressPayload(percentage: readingLocation?.percentage ?? 0)
    local.cfi = readingLocation?.cfi
    await position.refresh(local)
    await describePositionConflict(position)
  }

  func choosePosition(local: Bool) async {
    guard isReady, !isClosed, !isPositionResetting, !isNavigating, !isSaving else { return }
    guard let saved = await position.choose(local: local) else {
      await describePositionConflict(position)
      return
    }
    pendingProgress = nil
    if let progressKey { UserDefaults.standard.removeObject(forKey: progressKey) }
    isNavigating = true
    defer { isNavigating = false }
    do {
      guard let generation, try await api.authenticatedSessionGeneration() == generation else {
        throw ConnectionError.expiredSession
      }
      let raw = try await webView.callAsyncJavaScript(
        "return await window.epubGo(target)",
        arguments: ["target": saved.cfi.map { $0 as Any } ?? ["fraction": saved.percentage / 100]],
        in: nil, contentWorld: .page)
      guard !isClosed, try await api.authenticatedSessionGeneration() == generation else { return }
      location = try decodedLocation(raw)
      narrationLocation = nil
      selectionCFI = nil
      selectionText = ""
      status = "Chosen reading position saved."
      error = nil
    } catch { if !isClosed { self.error = error.localizedDescription } }
  }

  func adoptVisiblePosition() {
    guard !isClosed, !position.conflict.isBlocked, let narrationLocation else { return }
    location = narrationLocation
    self.narrationLocation = nil
  }

  func beginPositionReset() async throws {
    guard !isClosed else { throw CancellationError() }
    isPositionResetting = true
    position.suspendForReset(true)
    try await NativePositionResetWait.drain {
      self.isSaving || self.isNavigating || self.isSearching || self.position.isSaving
        || self.position.isResolving
    }
    await saveTask?.value
    try Task.checkCancellation()
  }

  func cancelPositionReset() {
    isPositionResetting = false
    position.suspendForReset(false)
  }

  func acknowledgePositionReset() {
    discardPendingProgress()
    position.acknowledgeReset()
  }

  func discardPendingProgress() {
    pendingProgress = nil
    if let progressKey { UserDefaults.standard.removeObject(forKey: progressKey) }
  }

  func close() {
    guard !isClosed else { return }
    isClosed = true
    finishNavigation(CancellationError())
    saveTask?.cancel()
    sessionTask?.cancel()
    cancelTurn?()
    webView.stopLoading()
    webView.navigationDelegate = nil
    webView.configuration.userContentController.removeAllScriptMessageHandlers()
    clearContent()
    resources.close()
    fontResources.close()
    preferences.close()
    position.close()
    prepareTurn = nil
    commitTurn = nil
    cancelTurn = nil
    results = []
    info = nil
    deliveredOutline = nil
    selectionText = ""
    selectionCFI = nil
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    guard navigation === expectedNavigation else { return }
    finishNavigation(nil)
  }

  func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: any Error
  ) {
    guard navigation === expectedNavigation else { return }
    finishNavigation(error)
    if !isClosed { self.error = error.localizedDescription }
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error)
  {
    self.webView(webView, didFailProvisionalNavigation: navigation, withError: error)
  }

  func webView(
    _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
  ) {
    let url = navigationAction.request.url
    let allowed =
      url == resources.entry || url?.absoluteString == "about:blank"
      || (navigationAction.targetFrame?.isMainFrame == false && url?.scheme == "blob")
    decisionHandler(
      allowed && (!isClosed || url?.absoluteString == "about:blank") ? .allow : .cancel)
  }

  func userContentController(
    _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
  ) {
    if annotationInputFixture, message.name == "selection" {
      let value = message.body as? [String: Any]
      let cfi = value?["cfi"] as? String ?? ""
      let text = value?["text"] as? String ?? ""
      let entryMatches = message.frameInfo.request.url == resources.entry
      let callbackKind = value == nil ? "empty" : "range"
      Self.fixtureLogger.info(
        "[epub.fixture_selection_callback] [end] bookId=\(self.bookID, privacy: .public) fileId=\(self.file.id, privacy: .public) durationMs=0 callbackKind=\(callbackKind, privacy: .public) mainFrame=\(message.frameInfo.isMainFrame, privacy: .public) entryMatches=\(entryMatches, privacy: .public) closed=\(self.isClosed, privacy: .public) resetting=\(self.isPositionResetting, privacy: .public) textChars=\(text.utf16.count, privacy: .public) cfiChars=\(cfi.utf16.count, privacy: .public) cfiPrefixValid=\(cfi.hasPrefix("epubcfi("), privacy: .public) - fixture selection bridge callback observed"
      )
    }
    guard !isClosed, !isPositionResetting, message.frameInfo.isMainFrame,
      message.frameInfo.request.url == resources.entry
    else { return }
    if message.name == "location" {
      if !isNavigating, let value = try? decodedLocation(message.body) {
        if (message.body as? [String: Any])?["source"] as? String == "narration" {
          narrationLocation = value
        } else {
          let moved = location?.cfi != value.cfi || location?.percentage != value.percentage
          location = value
          narrationLocation = nil
          if moved && !revealingAnnotation { scheduleSave() }
        }
      }
    } else if message.name == "readerError" {
      if let message = message.body as? String, !message.isEmpty, message.utf16.count <= 500 {
        error = message
      }
    } else if message.name == "pencilMarking", let marking = message.body as? Bool {
      isPencilMarking = marking
      webView.scrollView.isScrollEnabled = !marking
    } else if message.name == "pencilRelease", let value = message.body as? [String: Any],
      let identifier = value["operationId"] as? String,
      let operation = UUID(uuidString: identifier),
      let cfi = value["cfi"] as? String, cfi.hasPrefix("epubcfi("), cfi.utf16.count <= 2000,
      let text = value["text"] as? String, !text.isEmpty, text.utf16.count <= 16000
    {
      commitPencilHighlight?(
        .init(publicationID: publicationID, cfi: cfi, text: text, language: "en"), operation)
    } else if message.name == "passageAnnotation", let id = message.body as? Int {
      openPassageAnnotation?(id)
    } else if message.name == "selection" {
      if let value = message.body as? [String: Any], let cfi = value["cfi"] as? String,
        let text = value["text"] as? String, cfi.hasPrefix("epubcfi("), cfi.utf16.count <= 2000,
        !text.isEmpty, text.utf16.count <= 16000
      {
        selectionCFI = cfi
        selectionText = text
        let language = value["language"] as? String
        selectionLanguage = language.flatMap { $0.utf16.count <= 64 ? $0 : nil }
      } else {
        selectionCFI = nil
        selectionText = ""
        selectionLanguage = nil
      }
    }
  }

  @discardableResult
  private func navigate(
    _ script: String, arguments: [String: Any], forward: Bool, animate: Bool = true,
    allowPendingSave: Bool = false, programmatic: Bool = false,
    preserveContentOnFailure: Bool = false, savesPosition: Bool = true
  ) async -> Bool {
    guard isReady, !isNavigating, !isSearching, !isPositionResetting, !isClosed,
      allowPendingSave || (!isSaving && pendingProgress == nil)
    else { return false }
    isNavigating = true
    error = nil
    status = nil
    if !isSaving { saveTask?.cancel() }
    let originalLocation = location
    let movement =
      animate
      && (!(programmatic || isContinuous) || preferences.value.programmaticMovement == .smooth)
      && !reduceMotion
    let animation: ReaderTurnAnimation =
      !movement || isContinuous
      ? .none : preferences.value.pageAnimation
    var commandArguments = arguments
    if programmatic || isContinuous {
      commandArguments["smooth"] = movement && isContinuous
    }
    defer { isNavigating = false }
    do {
      guard let generation, try await api.authenticatedSessionGeneration() == generation else {
        throw ConnectionError.expiredSession
      }
      if animation != .none {
        let snapshot = try await webView.takeSnapshot(configuration: nil)
        prepareTurn?(snapshot)
      }
      let raw = try await webView.callAsyncJavaScript(
        script, arguments: commandArguments, in: nil, contentWorld: .page)
      let value = try decodedLocation(raw)
      guard !isClosed, try await api.authenticatedSessionGeneration() == generation else {
        throw ConnectionError.expiredSession
      }
      await commitTurn?(forward, animation)
      guard !isClosed, try await api.authenticatedSessionGeneration() == generation else {
        throw ConnectionError.expiredSession
      }
      location = value
      narrationLocation = nil
      selectionCFI = nil
      selectionText = ""
      if savesPosition { scheduleSave() }
      return true
    } catch {
      cancelTurn?()
      if !isClosed {
        self.error = error.localizedDescription
        if preserveContentOnFailure, let originalLocation, let generation,
          (try? await api.authenticatedSessionGeneration()) == generation,
          let raw = try? await webView.callAsyncJavaScript(
            "return await window.epubGo(target)", arguments: ["target": originalLocation.cfi],
            in: nil, contentWorld: .page),
          !isClosed, (try? await api.authenticatedSessionGeneration()) == generation,
          let restored = try? decodedLocation(raw)
        {
          location = restored
        } else {
          clearContent()
          resources.reset()
        }
      }
      return false
    }
  }

  private func scheduleSave() {
    annotationRevealOrigin = nil
    guard isReady, !isClosed, !isPositionResetting, !isSaving, pendingProgress == nil,
      !position.conflict.isBlocked
    else { return }
    if let progressKey, let location,
      let data = try? JSONEncoder().encode(
        EPUBProgressJournal(cfi: location.cfi, percentage: location.percentage))
    {
      UserDefaults.standard.set(data, forKey: progressKey)
    }
    saveTask?.cancel()
    saveTask = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(1)) } catch { return }
      guard let self, !self.isClosed else { return }
      await self.saveProgress()
    }
  }

  private func startSessionMonitor() {
    sessionTask?.cancel()
    sessionTask = Task { [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(10)) } catch { return }
        guard let self, !self.isClosed, let generation = self.generation else { return }
        do {
          guard try await self.api.authenticatedSessionGeneration() == generation else {
            throw ConnectionError.expiredSession
          }
        } catch {
          self.isReady = false
          self.error = "This reading session ended. Close the reader and sign in again."
          self.webView.stopLoading()
          self.clearContent()
          self.resources.close()
          self.fontResources.close()
          return
        }
      }
    }
  }

  private func decodedLocation(_ raw: Any?) throws -> EPUBReadingLocation {
    guard let value = raw as? [String: Any], let cfi = value["cfi"] as? String,
      cfi.hasPrefix("epubcfi("), cfi.utf16.count <= 2000,
      let percentage = value["percentage"] as? Double, percentage.isFinite,
      (0...100).contains(percentage),
      let index = value["chapterIndex"] as? Int, (0..<chapterCount).contains(index)
    else { throw ConnectionError.invalidResponse }
    let page = value["page"] as? Int
    let total = value["pageTotal"] as? Int
    let minutes = value["remainingMinutes"] as? Int
    let label = value["chapterLabel"] as? String ?? ""
    let locationNumber = value["locationNumber"] as? Int
    let locationTotal = value["locationTotal"] as? Int
    guard page.map({ (0...1_000_000).contains($0) }) ?? true,
      total.map({ (1...1_000_000).contains($0) }) ?? true,
      minutes.map({ (0...10_000_000).contains($0) }) ?? true, label.utf16.count <= 500
    else { throw ConnectionError.invalidResponse }
    guard
      (locationNumber == nil && locationTotal == nil)
        || (locationTotal.map({ $0 > 0 && $0 <= 9_007_199_254_740_991 }) == true
          && locationNumber.map({ $0 > 0 && $0 <= (locationTotal ?? 0) }) == true)
    else { throw ConnectionError.invalidResponse }
    preferences.setFixedLayout(value["fixedLayout"] as? Bool ?? false)
    return .init(
      cfi: cfi, percentage: percentage, chapterIndex: index,
      rightToLeft: value["rightToLeft"] as? Bool ?? false,
      page: page, pageTotal: total, remainingMinutes: minutes, chapterLabel: label,
      locationNumber: locationNumber, locationTotal: locationTotal)
  }

  func publicationCommand(_ script: String, arguments: [String: Any]) async throws -> Any? {
    guard isReady, !isClosed, !isNavigating, !isSearching, let generation,
      try await api.authenticatedSessionGeneration() == generation
    else { throw ConnectionError.expiredSession }
    let result = try await webView.callAsyncJavaScript(
      script, arguments: arguments, in: nil, contentWorld: .page)
    guard !isClosed, try await api.authenticatedSessionGeneration() == generation else {
      throw ConnectionError.expiredSession
    }
    return result
  }

  private func finishNavigation(_ failure: (any Error)?) {
    navigationTimeout?.cancel()
    navigationTimeout = nil
    expectedNavigation = nil
    let continuation = navigationWait
    navigationWait = nil
    if let failure { continuation?.resume(throwing: failure) } else { continuation?.resume() }
  }

  private func clearContent() {
    isPencilMarking = false
    publicationID = UUID()
    selectionLanguage = nil
    saveTask?.cancel()
    webView.stopLoading()
    webView.loadHTMLString("", baseURL: nil)
    location = nil
    narrationLocation = nil
    selectionCFI = nil
    selectionText = ""
    isReady = false
  }

  private func renderSettings(_ value: EPUBPreferencesValue? = nil, hideCustomFont: Bool = false)
    throws -> Any
  {
    var settings = (value ?? preferences.value).settings
    if hideCustomFont && EPUBCustomFontsModel.isCustom(settings.fontFamily) {
      settings.fontFamily = nil
    }
    settings.fontSize = Double(
      UIFontMetrics(forTextStyle: .body).scaledValue(for: CGFloat(settings.fontSize)))
    guard var rendered = try json(settings) as? [String: Any] else {
      throw ConnectionError.invalidResponse
    }
    rendered["nativeContinuousAxis"] = (value ?? preferences.value).continuousAxis.rawValue
    return rendered
  }

  private func prepareFontSelection(_ requested: EPUBPreferencesValue) async throws {
    guard !isClosed, let generation,
      try await api.authenticatedSessionGeneration() == generation
    else { throw ConnectionError.expiredSession }
    let family = try preferences.fonts.resolve(requested.settings.fontFamily)
    let faces = try fontResources.prepare(
      family, weight: requested.settings.fontWeight,
      style: requested.settings.fontStyle, session: generation)
    do {
      let raw = try await webView.callAsyncJavaScript(
        "return await window.epubPrepareFonts(faces, settings)",
        arguments: ["faces": try json(faces), "settings": try renderSettings(requested)],
        in: nil, contentWorld: .page)
      guard raw as? Bool == true, !isClosed,
        try await api.authenticatedSessionGeneration() == generation
      else { throw EPUBFontError.loadFailed }
    } catch {
      if let message = fontResources.failure { throw DeliveredEbookFailure(message: message) }
      if error is CancellationError || error is ConnectionError { throw error }
      throw EPUBFontError.loadFailed
    }
  }

  private func restoreCustomTypography() async throws {
    fontFailure = nil
    let cfi = location?.cfi
    do {
      let supports =
        try await webView.callAsyncJavaScript(
          "return !document.querySelector('foliate-view').isFixedLayout", arguments: [:],
          in: nil, contentWorld: .page) as? Bool == true
      if supports && preferences.useFormatting {
        try await prepareFontSelection(preferences.value)
      } else if let generation {
        _ = try fontResources.prepare(nil, weight: 400, style: "normal", session: generation)
        _ = try await webView.callAsyncJavaScript(
          "return await window.epubPrepareFonts([], settings)",
          arguments: ["settings": try renderSettings(hideCustomFont: true)],
          in: nil, contentWorld: .page)
      }
      if isLoading, supports, preferences.useFormatting, let cfi {
        let raw = try await webView.callAsyncJavaScript(
          "return await window.epubConfigure(settings, formatting, cfi)",
          arguments: ["settings": try renderSettings(), "formatting": true, "cfi": cfi],
          in: nil, contentWorld: .page)
        self.location = try decodedLocation(raw)
      }
    } catch {
      guard !isClosed, EPUBCustomFontsModel.isCustom(preferences.value.settings.fontFamily),
        let generation, let cfi
      else { throw error }
      let message = error.localizedDescription
      _ = try fontResources.prepare(nil, weight: 400, style: "normal", session: generation)
      _ = try await webView.callAsyncJavaScript(
        "return await window.epubPrepareFonts([], settings)",
        arguments: ["settings": try renderSettings(hideCustomFont: true)],
        in: nil, contentWorld: .page)
      let raw = try await webView.callAsyncJavaScript(
        "return await window.epubConfigure(settings, formatting, cfi)",
        arguments: [
          "settings": try renderSettings(hideCustomFont: true),
          "formatting": preferences.useFormatting, "cfi": cfi,
        ], in: nil, contentWorld: .page)
      location = try decodedLocation(raw)
      fontFailure =
        "Saved custom typography is unavailable. The publisher font is shown. \(message)"
    }
  }

  private func json<Value: Encodable>(_ value: Value) throws -> Any {
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
  }
}
