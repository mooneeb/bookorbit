import ImageIO
import UIKit

actor DashboardCoverLoader {
  static let shared = DashboardCoverLoader()
  private var active = 0
  private var waiting: [CheckedContinuation<Void, Never>] = []
  private var images: [String: UIImage] = [:]
  private var order: [String] = []

  func image(api: BookOrbitAPI, book: BookCard, medium: CoverMedium, namespace: String) async throws
    -> UIImage
  {
    try Task.checkCancellation()
    let key = "\(namespace).\(book.id).\(medium.rawValue).\(book.coverVersion)"
    if let image = images[key] { return image }
    if active < 3 {
      active += 1
    } else {
      guard waiting.count < 32 else { throw DashboardCoverError.busy }
      await withCheckedContinuation { waiting.append($0) }
    }
    defer { release() }
    try Task.checkCancellation()
    let data: Data
    do {
      data = try await api.coverImage(bookID: book.id, medium: medium, version: book.coverVersion)
    } catch ConnectionError.http(404) {
      data = try await api.coverImage(
        bookID: book.id,
        medium: medium == .ebook ? .audio : .ebook, version: book.coverVersion)
    }
    try Task.checkCancellation()
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
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

  private func release() {
    if waiting.isEmpty { active -= 1 } else { waiting.removeFirst().resume() }
  }
}

private enum DashboardCoverError: Error { case busy }
