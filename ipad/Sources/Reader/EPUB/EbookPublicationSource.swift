import Foundation

enum EbookPublicationSource {
  case epub
  case delivered(format: String, mimeType: String, size: Int?, maximumSize: Int)

  static func resolve(_ file: BookDetailFile) throws -> Self {
    guard let format = file.format?.lowercased(),
      let mimeType = NativeEbookVocabulary.mimeTypes[format]
    else { throw ConnectionError.invalidResponse }
    if format == "epub" { return .epub }
    let maximum = format == "fb2" ? 32 * 1024 * 1024 : 64 * 1024 * 1024
    var expected: Int?
    if let size = file.sizeBytes {
      guard size.isFinite, size > 0, size.rounded() == size else {
        throw ConnectionError.invalidResponse
      }
      guard size <= Double(maximum) else { throw ConnectionError.resourceTooLarge }
      expected = Int(size)
    }
    return .delivered(format: format, mimeType: mimeType, size: expected, maximumSize: maximum)
  }
}

struct DeliveredEbookOutline: Decodable {
  let sectionCount: Int
  let toc: [EpubTocItem]
}

struct DeliveredEbookFailure: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}
