import CoreTransferable
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum CoverImageError: LocalizedError {
  case tooLarge
  case invalidImage

  var errorDescription: String? {
    switch self {
    case .tooLarge: "Choose an image smaller than 20 MB."
    case .invalidImage: "This image could not be opened. Choose another image."
    }
  }
}

struct StagedCoverImage: Transferable, Sendable {
  let file: URL
  let preview: Data
  let width: Int
  let height: Int
  let contentType: String

  static var transferRepresentation: some TransferRepresentation {
    FileRepresentation(importedContentType: .image) { received in
      try await CoverImageImport.shared.prepare(received.file)
    }
  }
}

actor CoverImageImport {
  static let shared = CoverImageImport()
  static let byteLimit = 20 * 1024 * 1024

  func prepare(_ file: URL) throws -> StagedCoverImage {
    let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize
    guard let size, size > 0, size <= Self.byteLimit else { throw CoverImageError.tooLarge }
    guard
      let source = CGImageSourceCreateWithURL(
        file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
    else {
      throw CoverImageError.invalidImage
    }
    guard let identifier = CGImageSourceGetType(source),
      let type = UTType(identifier as String), type.conforms(to: .image),
      let contentType = type.preferredMIMEType,
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int,
      width > 0, height > 0
    else { throw CoverImageError.invalidImage }
    let preview = try Self.encodedPreview(source)
    try Task.checkCancellation()
    let output = FileManager.default.temporaryDirectory.appendingPathComponent(
      "cover-\(UUID().uuidString)")
    var completed = false
    defer { if !completed { try? FileManager.default.removeItem(at: output) } }
    try FileManager.default.copyItem(at: file, to: output)
    guard try output.resourceValues(forKeys: [.fileSizeKey]).fileSize == size else {
      throw CoverImageError.invalidImage
    }
    try Task.checkCancellation()
    completed = true
    return StagedCoverImage(
      file: output, preview: preview, width: width, height: height, contentType: contentType)
  }

  func preview(_ data: Data) throws -> Data {
    guard data.count <= Self.byteLimit,
      let source = CGImageSourceCreateWithData(
        data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
    else { throw CoverImageError.invalidImage }
    return try Self.encodedPreview(source)
  }

  private static func thumbnail(_ source: CGImageSource, maximum: Int) throws -> CGImage {
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maximum,
      kCGImageSourceShouldCacheImmediately: true,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
      throw CoverImageError.invalidImage
    }
    return image
  }

  private static func encodedPreview(_ source: CGImageSource) throws -> Data {
    let image = try thumbnail(source, maximum: 400)
    let output = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        output, UTType.png.identifier as CFString, 1, nil)
    else {
      throw CoverImageError.invalidImage
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw CoverImageError.invalidImage }
    return output as Data
  }
}
