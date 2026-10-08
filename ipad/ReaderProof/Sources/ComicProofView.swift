import SwiftUI

struct ComicProofView: View {
  let api: BookOrbitAPI
  let bookID: Int
  let file: BookDetailFile

  var body: some View {
    ComicReaderView(
      api: api, bookID: bookID, file: file, title: "Comic reader proof", showsPageControls: false)
  }
}
