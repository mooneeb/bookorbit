import SwiftUI
import UniformTypeIdentifiers

struct AnnotationHubExportDocument: FileDocument {
  static var readableContentTypes: [UTType] { [.json] }
  static let byteLimit = 16 * 1024 * 1024
  let data: Data

  init(data: Data) { self.data = data }

  init(configuration: ReadConfiguration) throws {
    guard let data = configuration.file.regularFileContents, data.count <= Self.byteLimit else {
      throw AnnotationHubError(
        message: String(localized: "This annotation export could not be read."))
    }
    self.data = data
  }

  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    guard data.count <= Self.byteLimit else {
      throw AnnotationHubError(message: String(localized: "This annotation export is too large."))
    }
    return FileWrapper(regularFileWithContents: data)
  }
}
