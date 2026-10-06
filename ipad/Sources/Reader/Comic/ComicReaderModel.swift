import Foundation
import Observation
import UIKit

@MainActor @Observable
final class ComicReaderModel {
  let api: BookOrbitAPI
  let file: BookDetailFile
  private(set) var pageCount = 0
  private(set) var pageIndex = 0
  private(set) var images: [Int: UIImage] = [:]
  private(set) var pageErrors: [Int: String] = [:]
  private(set) var error: String?
  private(set) var status = ""
  private(set) var isClosing = false
  var hasUnsavedPosition: Bool { pendingPage != nil && saveTask == nil }
  private let loader: ComicPageLoader
  private var loadTask: Task<Void, Never>?
  private var saveTask: Task<Void, Never>?
  private var pendingPage: Int?
  private var isLoading = false
  private var isClosed = false
  private var pageLayout = FixedPageLayout(pageCount: 0, facing: false, singlePrefix: 0)
  private var continuousVisible: Set<Int>?

  init(api: BookOrbitAPI, file: BookDetailFile) {
    self.api = api
    self.file = file
    loader = ComicPageLoader(api: api, fileID: file.id)
  }

  func load() async {
    guard pageCount == 0, !isLoading, !isClosed else { return }
    isLoading = true
    error = nil
    defer { isLoading = false }
    do {
      let count: ComicPageCountResponse = try await api.send("cbz/files/\(file.id)/pages")
      let progress: FileReadingProgress = try await api.send("books/files/\(file.id)/progress")
      try Task.checkCancellation()
      guard !isClosed else { return }
      guard (1...100_000).contains(count.pageCount) else { throw ConnectionError.invalidResponse }
      pageCount = count.pageCount
      if let page = progress.pageNumber, page.isFinite, page >= 1, page <= Double(pageCount) {
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
    guard !isClosed, !isClosing, (0..<pageCount).contains(index), index != pageIndex else { return }
    pageIndex = index
    loadVisiblePages()
    pendingPage = index + 1
    status = "Saving position…"
    if saveTask == nil { saveTask = Task { await savePendingPosition() } }
  }

  func retryPages() { loadVisiblePages() }

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
        try await api.sendEmpty(
          "books/files/\(file.id)/progress", body: JSONEncoder().encode(payload))
        guard !isClosed else { return }
        if pendingPage == nil {
          status = "Position saved"
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
    guard !isClosed, saveTask == nil, pendingPage != nil else { return }
    status = "Saving position…"
    error = nil
    saveTask = Task { await savePendingPosition() }
  }

  func prepareToClose() async -> Bool {
    guard !isClosed, !isClosing else { return false }
    isClosing = true
    defer { isClosing = false }
    retrySaving()
    await saveTask?.value
    return pendingPage == nil
  }

  func close() {
    isClosed = true
    loadTask?.cancel()
    saveTask?.cancel()
    images = [:]
    pageErrors = [:]
  }
}
