import SwiftUI

struct ComicProofView: View {
  let api: BookOrbitAPI
  let file: BookDetailFile

  var body: some View {
    ComicReaderView(
      api: api, file: file, title: "Comic reader proof", showsPageControls: false)
  }
}
