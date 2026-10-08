import SwiftUI

struct NativeReaderHost: View {
  let api: BookOrbitAPI
  let bookID: Int
  let files: [BookDetailFile]
  let title: String
  let language: String?
  @State private var file: BookDetailFile
  @State private var continuation: BookContinuationTarget?

  init(
    api: BookOrbitAPI, bookID: Int, file: BookDetailFile, files: [BookDetailFile], title: String,
    language: String?
  ) {
    self.api = api
    self.bookID = bookID
    self.files = files
    self.title = title
    self.language = language
    _file = State(initialValue: file)
  }

  var body: some View {
    Group {
      if NativeEbookVocabulary.mimeTypes[file.format?.lowercased() ?? ""] != nil {
        EPUBReaderView(
          api: api, bookID: bookID, file: file, title: title, language: language,
          files: files, continuation: continuation, onContinue: switchReader)
      } else if ["cbz", "cbr", "cb7"].contains(file.format?.lowercased() ?? "") {
        ComicReaderHost(api: api, bookID: bookID, file: file)
      } else if AudioStreamFormat.mimeTypes[file.format?.lowercased() ?? ""] != nil {
        AudiobookReaderView(
          api: api, bookID: bookID, file: file,
          files: files, continuation: continuation, onContinue: switchReader)
      } else {
        PDFReaderView(api: api, bookID: bookID, file: file)
      }
    }
    .id(file.id)
  }

  private func switchReader(_ destination: NativeContinuationDestination) {
    continuation = destination.position
    file = destination.file
  }
}
