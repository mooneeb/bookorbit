import PDFKit
import UIKit

@MainActor
final class PDFThumbnailRenderer {
  private struct Demand {
    let id: UUID
    let complete: (UIImage?) -> Void
  }

  private struct CachedPreview {
    let image: UIImage?
    let byteCount: Int
  }

  private var document: PDFDocument?
  private var rotation = 0
  private var authorize: (@MainActor () async -> Bool)?
  private var unavailable: (() -> Void)?
  private var generation = UUID()
  private var demands: [Int: Demand] = [:]
  private var queue: [Int] = []
  private var cache: [Int: CachedPreview] = [:]
  private var recent: [Int] = []
  private var cacheBytes = 0
  private var activePage: Int?
  private var work: Task<Void, Never>?
  private let maximumRequests = 128
  private let maximumCachedPages = 24
  private let maximumCacheBytes = 8 * 1024 * 1024

  func configure(
    document: PDFDocument, rotation: Int, authorize: @escaping @MainActor () async -> Bool,
    unavailable: @escaping () -> Void
  ) {
    if self.document !== document || self.rotation != rotation { stop() }
    self.document = document
    self.rotation = rotation
    self.authorize = authorize
    self.unavailable = unavailable
  }

  func request(page: Int, id: UUID, complete: @escaping (UIImage?) -> Void) {
    guard let document, !document.isLocked, (0..<document.pageCount).contains(page) else {
      complete(nil)
      return
    }
    guard demands[page] != nil || demands.count < maximumRequests else {
      complete(nil)
      return
    }
    if let previous = demands[page], previous.id != id {
      queue.removeAll { $0 == page }
      queue.append(page)
      if activePage == page { work?.cancel() }
    } else if demands[page] == nil {
      queue.append(page)
    }
    demands[page] = Demand(id: id, complete: complete)
    renderNext()
  }

  func release(page: Int, id: UUID) {
    guard demands[page]?.id == id else { return }
    demands.removeValue(forKey: page)
    queue.removeAll { $0 == page }
    if activePage == page { work?.cancel() }
  }

  func stop() {
    generation = UUID()
    work?.cancel()
    document = nil
    authorize = nil
    unavailable = nil
    demands.removeAll()
    queue.removeAll()
    cache.removeAll()
    recent.removeAll()
    cacheBytes = 0
  }

  private func renderNext() {
    guard work == nil, document != nil, let authorize else { return }
    while let page = queue.first {
      queue.removeFirst()
      guard let demand = demands[page] else { continue }
      let generation = self.generation
      activePage = page
      work = Task { [weak self] in
        guard let self else { return }
        let allowed = await authorize()
        guard self.generation == generation, !Task.isCancelled,
          self.demands[page]?.id == demand.id
        else {
          self.finishWork()
          return
        }
        guard allowed, self.document?.isLocked == false else {
          let unavailable = self.unavailable
          self.stop()
          self.finishWork()
          unavailable?()
          return
        }
        if let cached = self.cache[page] {
          self.touch(page)
          self.demands.removeValue(forKey: page)
          demand.complete(cached.image)
          self.finishWork()
          return
        }
        guard let sourcePage = self.document?.page(at: page), let reference = sourcePage.pageRef,
          let snapshot = sourcePage.copy() as? PDFPage
        else {
          self.complete(page: page, demand: demand, bitmap: nil)
          self.finishWork()
          return
        }
        let source = PDFThumbnailPage(
          page: reference, snapshot: snapshot, bounds: sourcePage.bounds(for: .cropBox),
          pageTransform: snapshot.transform(for: .cropBox), rotation: self.rotation)
        let worker = Task.detached(priority: .utility) { PDFThumbnailRasterizer.render(source) }
        let bitmap = await withTaskCancellationHandler {
          await worker.value
        } onCancel: {
          worker.cancel()
        }
        let stillAllowed: Bool
        if Task.isCancelled {
          stillAllowed = false
        } else {
          stillAllowed = await authorize()
        }
        if self.generation == generation, !Task.isCancelled,
          self.demands[page]?.id == demand.id
        {
          if stillAllowed {
            self.complete(page: page, demand: demand, bitmap: bitmap)
          } else {
            let unavailable = self.unavailable
            self.stop()
            unavailable?()
          }
        }
        self.finishWork()
      }
      return
    }
  }

  private func complete(page: Int, demand: Demand, bitmap: PDFThumbnailBitmap?) {
    let preview = CachedPreview(
      image: bitmap.map { UIImage(cgImage: $0.image) }, byteCount: bitmap?.byteCount ?? 0)
    cache[page] = preview
    cacheBytes += preview.byteCount
    touch(page)
    while cache.count > maximumCachedPages || cacheBytes > maximumCacheBytes {
      guard let oldest = recent.first else { break }
      recent.removeFirst()
      cacheBytes -= cache.removeValue(forKey: oldest)?.byteCount ?? 0
    }
    demands.removeValue(forKey: page)
    demand.complete(preview.image)
  }

  private func touch(_ page: Int) {
    recent.removeAll { $0 == page }
    recent.append(page)
  }

  private func finishWork() {
    activePage = nil
    work = nil
    renderNext()
  }
}
