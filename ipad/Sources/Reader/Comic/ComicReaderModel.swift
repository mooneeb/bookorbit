import Foundation
import Observation
import UIKit

@MainActor @Observable
final class ComicReaderModel {
  let api: BookOrbitAPI
  let file: BookDetailFile
  let position: NativeFilePositionModel
  private(set) var pageCount = 0
  private(set) var pageIndex = 0
  private(set) var images: [Int: UIImage] = [:]
  private(set) var pageErrors: [Int: String] = [:]
  private(set) var error: String?
  private(set) var status = ""
  private(set) var isPositionResetting = false
  private(set) var isClosing = false
  var hasUnsavedPosition: Bool {
    (pendingPage != nil || position.conflict.isBlocked) && saveTask == nil
  }
  private let loader: ComicPageLoader
  private var loadTask: Task<Void, Never>?
  private var saveTask: Task<Void, Never>?
  private var pendingPage: Int?
  private var isLoading = false
  private var isClosed = false
  private var pageLayout = FixedPageLayout(pageCount: 0, facing: false, singlePrefix: 0)
  private var continuousVisible: Set<Int>?
  private var widePages: Set<Int> = []
  private var pendingWidePages: Set<Int> = []
  private var isTurning = false
  private(set) var normalFacingLayout = FixedPageLayout(pageCount: 0, facing: true, singlePrefix: 1)
  private(set) var shiftedFacingLayout = FixedPageLayout(
    pageCount: 0, facing: true, singlePrefix: 2)

  init(api: BookOrbitAPI, file: BookDetailFile) {
    self.api = api
    self.file = file
    position = NativeFilePositionModel(
      api: api, fileID: file.id,
      sourceIdentity: file.absolutePath + ":" + String(file.sizeBytes ?? -1))
    loader = ComicPageLoader(api: api, fileID: file.id)
  }

  func load() async {
    guard pageCount == 0, !isLoading, !isClosed else { return }
    isLoading = true
    error = nil
    defer { isLoading = false }
    do {
      let count: ComicPageCountResponse = try await api.send("cbz/files/\(file.id)/pages")
      let positionSession = try await api.authenticatedSessionGeneration()
      let progress: FileReadingProgress = try await api.boundedJSON(
        "books/files/\(file.id)/progress", byteLimit: 16 * 1024, session: positionSession)
      try await position.accept(progress, session: positionSession)
      try Task.checkCancellation()
      guard !isClosed else { return }
      guard (1...100_000).contains(count.pageCount) else { throw ConnectionError.invalidResponse }
      pageCount = count.pageCount
      var beginning = SaveFileProgressPayload(percentage: 100 / Double(pageCount))
      beginning.pageNumber = 1
      position.setBeginning(beginning)
      updateFacingLayouts()
      if let page = position.resumePageNumber, page.isFinite, page >= 1, page <= Double(pageCount) {
        pageIndex = Int(page.rounded(.down)) - 1
      }
      error = nil
      loadVisiblePages()
    } catch is CancellationError {
    } catch {
      if !isClosed { self.error = error.localizedDescription }
    }
  }

  func didTurn(to index: Int) {
    guard !isClosed, !isPositionResetting, !isClosing, !position.conflict.isBlocked,
      (0..<pageCount).contains(index), index != pageIndex
    else { return }
    pageIndex = index
    loadVisiblePages()
    pendingPage = index + 1
    status = "Saving position…"
    if saveTask == nil { saveTask = Task { await savePendingPosition() } }
  }

  func retryPages() { loadVisiblePages() }

  func noteTransition(_ active: Bool) {
    isTurning = active
    if !active { commitWidePages() }
  }

  private func commitWidePages() {
    let added = pendingWidePages.subtracting(widePages)
    pendingWidePages = []
    guard !added.isEmpty else { return }
    widePages.formUnion(added)
    updateFacingLayouts()
  }

  private func updateFacingLayouts() {
    let ordered = widePages.sorted()
    normalFacingLayout = FixedPageLayout(
      pageCount: pageCount, facing: true, singlePrefix: 1, widePages: ordered,
      revision: widePages.count)
    shiftedFacingLayout = FixedPageLayout(
      pageCount: pageCount, facing: true, singlePrefix: 2, widePages: ordered,
      revision: widePages.count)
  }

  func configureLayout(_ layout: FixedPageLayout) {
    guard !isClosed, layout.pageCount == pageCount, layout != pageLayout else { return }
    pageLayout = layout
    loadVisiblePages()
  }

  private var loadedWindow: Set<Int> {
    if let visible = continuousVisible {
      var window = visible
      if let first = visible.min(), first > 0 { window.insert(first - 1) }
      if let last = visible.max(), last + 1 < pageCount { window.insert(last + 1) }
      window.insert(pageIndex)
      return window
    }
    let layout =
      pageLayout.pageCount == pageCount
      ? pageLayout : FixedPageLayout(pageCount: pageCount, facing: false, singlePrefix: 0)
    return layout.visibleWindow(around: pageIndex)
  }

  func configureContinuous(_ enabled: Bool) {
    if enabled == (continuousVisible != nil) { return }
    continuousVisible = enabled ? [pageIndex] : nil
    loadVisiblePages()
  }

  func showContinuousPages(_ pages: Set<Int>) {
    guard !isClosed, continuousVisible != nil else { return }
    let bounded = Set(pages.filter { (0..<pageCount).contains($0) }.sorted().prefix(32))
    guard !bounded.isEmpty, bounded != continuousVisible else { return }
    continuousVisible = bounded
    loadVisiblePages()
  }

  private func loadVisiblePages() {
    loadTask?.cancel()
    guard !isClosed, pageCount > 0 else { return }
    let window = loadedWindow
    images = images.filter { window.contains($0.key) }
    pageErrors = pageErrors.filter { window.contains($0.key) }
    let indices = window.sorted {
      let left = abs($0 - pageIndex)
      let right = abs($1 - pageIndex)
      return left == right ? $0 < $1 : left < right
    }
    loadTask = Task {
      for index in indices {
        guard !isClosed, !Task.isCancelled else { return }
        if images[index] != nil { continue }
        pageErrors[index] = nil
        do {
          let image = try await loader.image(at: index)
          try Task.checkCancellation()
          guard !isClosed, loadedWindow.contains(index) else { return }
          images[index] = image
          if image.size.height > 0,
            image.size.width / image.size.height >= CGFloat(ReaderLayoutBounds.widePageRatio)
          {
            pendingWidePages.insert(index)
            if !isTurning { commitWidePages() }
          }
        } catch is CancellationError {
          return
        } catch {
          guard !isClosed, !Task.isCancelled else { return }
          pageErrors[index] = error.localizedDescription
        }
      }
    }
  }

  private func savePendingPosition() async {
    defer { saveTask = nil }
    while let page = pendingPage, !isClosed, !Task.isCancelled {
      pendingPage = nil
      do {
        var payload = SaveFileProgressPayload(percentage: Double(page) / Double(pageCount) * 100)
        payload.source = "text"
        payload.pageNumber = Double(page)
        try Task.checkCancellation()
        guard !isClosed else { return }
        guard let saved = await position.save(payload) else {
          if pendingPage == nil { pendingPage = page }
          error = position.message
          status = "Position could not be saved."
          return
        }
        if saved.pageNumber != Double(page) {
          if pendingPage == nil { pendingPage = page }
          continue
        }
        guard !isClosed else { return }
        if pendingPage == nil {
          status = position.hasPendingSync ? "Position saved on this iPad" : "Position saved"
          error = nil
        }
      } catch {
        guard !isClosed else { return }
        if pendingPage == nil { pendingPage = page }
        self.error = error.localizedDescription
        status = "Position could not be saved."
        return
      }
    }
  }

  func retrySaving() {
    guard !isClosed, !isPositionResetting, saveTask == nil, pendingPage != nil,
      !position.conflict.isBlocked
    else { return }
    status = "Saving position…"
    error = nil
    saveTask = Task { await savePendingPosition() }
  }

  func refreshPosition() async {
    guard !isClosed, !isPositionResetting, !isClosing, saveTask == nil, pageCount > 0 else {
      return
    }
    var local = SaveFileProgressPayload(percentage: Double(pageIndex + 1) / Double(pageCount) * 100)
    local.pageNumber = Double(pageIndex + 1)
    await position.refresh(local)
  }

  func choosePosition(local: Bool) async {
    guard !isClosed, !isPositionResetting, !isClosing, saveTask == nil,
      let saved = await position.choose(local: local),
      let page = saved.pageNumber, page.isFinite, page >= 1, page <= Double(pageCount)
    else { return }
    pageIndex = Int(page) - 1
    pendingPage = nil
    status = "Chosen reading position saved."
    error = nil
    loadVisiblePages()
  }

  func prepareToClose() async -> Bool {
    guard !isClosed, !isClosing else { return false }
    isClosing = true
    defer { isClosing = false }
    retrySaving()
    await saveTask?.value
    return pendingPage == nil && !position.conflict.isBlocked
  }

  func beginPositionReset() async throws {
    guard !isClosed, !isClosing else { throw CancellationError() }
    isPositionResetting = true
    position.suspendForReset(true)
    try await NativePositionResetWait.drain {
      self.saveTask != nil || self.position.isSaving || self.position.isResolving
    }
  }

  func cancelPositionReset() {
    isPositionResetting = false
    position.suspendForReset(false)
  }

  func acknowledgePositionReset() {
    pendingPage = nil
    position.acknowledgeReset()
  }

  func close() {
    isClosed = true
    position.close()
    loadTask?.cancel()
    saveTask?.cancel()
    images = [:]
    pageErrors = [:]
    widePages = []
    pendingWidePages = []
    normalFacingLayout = FixedPageLayout(pageCount: 0, facing: true, singlePrefix: 1)
    shiftedFacingLayout = FixedPageLayout(pageCount: 0, facing: true, singlePrefix: 2)
  }
}
