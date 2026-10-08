import Foundation
import Observation

@MainActor @Observable
final class NativeChapterModel {
  let api: BookOrbitAPI
  let bookID: Int
  let file: BookDetailFile
  private(set) var chapter: NativeChapterDocument?
  private(set) var error: String?
  private var started = false
  private var isClosed = false

  init(api: BookOrbitAPI, bookID: Int, file: BookDetailFile) {
    self.api = api
    self.bookID = bookID
    self.file = file
  }

  func load() async {
    guard !started, !isClosed else { return }
    started = true
    do {
      let info: EpubBookInfo = try await api.send(
        "epub/\(bookID)/info", query: [URLQueryItem(name: "fileId", value: String(file.id))])
      try Task.checkCancellation()
      guard !isClosed else { return }
      guard let spine = info.spine.first(where: \.linear),
        spine.mediaType == "application/xhtml+xml",
        let resource = info.manifest.first(where: { $0.id == spine.idref && $0.href == spine.href }
        ),
        resource.mediaType == spine.mediaType,
        !resource.href.hasPrefix("/"), !resource.href.contains("\\"),
        !resource.href.split(separator: "/").contains(".."), resource.href.utf16.count <= 4096
      else { throw NativeChapterError.unsupported }
      guard (0...(64 * 1024)).contains(resource.size) else { throw NativeChapterError.tooLarge }
      let data = try await api.epubResource(
        bookID: bookID, fileID: file.id, path: resource.href, expectedSize: resource.size)
      try Task.checkCancellation()
      guard !isClosed else { return }
      chapter = try NativeChapterDocument.parse(data)
    } catch is CancellationError {
      close()
    } catch {
      if !isClosed { self.error = error.localizedDescription }
    }
  }

  func close() {
    isClosed = true
    chapter = nil
  }
}
