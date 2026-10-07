import ImageIO
import UIKit

actor CoverPreviewLoader {
  static let shared = CoverPreviewLoader()
  private var active = 0
  private struct Waiter {
    let id: UUID
    let continuation: CheckedContinuation<Void, Error>
  }
  private var waiting: [Waiter] = []
  private var images: [String: UIImage] = [:]
  private var order: [String] = []

  func image(api: BookOrbitAPI, book: BookCard, medium: CoverMedium, namespace: String) async throws
    -> UIImage
  {
    let key = "\(namespace).\(book.id).\(medium.rawValue).\(book.coverVersion)"
    return try await image(key: key) {
      do {
        return try await api.coverImage(bookID: book.id, medium: medium, version: book.coverVersion)
      } catch ConnectionError.http(404) {
        return try await api.coverImage(
          bookID: book.id, medium: medium == .ebook ? .audio : .ebook, version: book.coverVersion)
      }
    }
  }

  func image(api: BookOrbitAPI, url: String) async throws -> UIImage {
    let namespace = try await api.imageNamespace()
    return try await image(key: namespace + ".remote." + url) {
      try await api.remoteCoverPreview(url: url)
    }
  }

  func thumbnail(api: BookOrbitAPI, bookID: Int, version: String, namespace: String) async throws
    -> UIImage
  {
    guard try await api.imageNamespace() == namespace else { throw ConnectionError.expiredSession }
    let result = try await image(key: "\(namespace).thumbnail.\(bookID).\(version)") {
      try await api.thumbnailImage(bookID: bookID, version: version, namespace: namespace)
    }
    try Task.checkCancellation()
    guard try await api.imageNamespace() == namespace else { throw ConnectionError.expiredSession }
    return result
  }

  private func image(key: String, load: @Sendable () async throws -> Data) async throws -> UIImage {
    try Task.checkCancellation()
    if let image = images[key] { return image }
    try await acquire()
    defer { release() }
    try Task.checkCancellation()
    if let image = images[key] { return image }
    let data = try await load()
    try Task.checkCancellation()
    guard
      let source = CGImageSourceCreateWithData(
        data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
      let decoded = CGImageSourceCreateThumbnailAtIndex(
        source, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceThumbnailMaxPixelSize: 400,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    else { throw CoverImageError.invalidImage }
    let image = UIImage(cgImage: decoded)
    if images[key] == nil { order.append(key) }
    images[key] = image
    while order.count > 24 { images.removeValue(forKey: order.removeFirst()) }
    return image
  }

  private func acquire() async throws {
    try Task.checkCancellation()
    if active < 3 {
      active += 1
      return
    }
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, Error>) in
        guard !Task.isCancelled else {
          continuation.resume(throwing: CancellationError())
          return
        }
        guard waiting.count < 32 else {
          continuation.resume(throwing: CoverPreviewError.busy)
          return
        }
        waiting.append(Waiter(id: id, continuation: continuation))
      }
    } onCancel: {
      Task { await self.cancelWaiter(id) }
    }
  }

  private func cancelWaiter(_ id: UUID) {
    guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
    waiting.remove(at: index).continuation.resume(throwing: CancellationError())
  }

  private func release() {
    if waiting.isEmpty { active -= 1 } else { waiting.removeFirst().continuation.resume() }
  }
}

private enum CoverPreviewError: LocalizedError {
  case busy
  var errorDescription: String? { "Cover previews are busy. Retry in a moment." }
}
