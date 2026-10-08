import ImageIO
import UIKit
import UniformTypeIdentifiers

actor ComicPageLoader {
  let api: BookOrbitAPI
  let fileID: Int

  init(api: BookOrbitAPI, fileID: Int) {
    self.api = api
    self.fileID = fileID
  }

  func image(at index: Int) async throws -> UIImage {
    let data = try await api.comicPage(fileID: fileID, pageIndex: index)
    try Task.checkCancellation()
    guard
      let source = CGImageSourceCreateWithData(
        data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
      let type = CGImageSourceGetType(source), UTType(type as String)?.conforms(to: .image) == true,
      let image = CGImageSourceCreateThumbnailAtIndex(
        source, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceThumbnailMaxPixelSize: 3072,
          kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    else { throw ConnectionError.invalidResponse }
    try Task.checkCancellation()
    return UIImage(cgImage: image)
  }
}
