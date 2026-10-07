import SwiftUI

struct ComicReaderHost: View {
  let api: BookOrbitAPI
  @State private var target: ComicReaderTarget

  init(api: BookOrbitAPI, bookID: Int, file: BookDetailFile) {
    self.api = api
    _target = State(
      initialValue: ComicReaderTarget(bookID: bookID, file: file, title: "Comic reader"))
  }

  var body: some View {
    ComicReaderView(
      api: api, bookID: target.bookID, file: target.file, title: target.title,
      onOpenNext: { target = $0 }
    ).id("\(target.bookID)/\(target.file.id)")
  }
}
