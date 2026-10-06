import SwiftUI

struct RemoteCoverPreview: View {
  let api: BookOrbitAPI
  let url: String
  var label = "Proposed cover"
  @State private var image: UIImage?
  @State private var error: String?

  var body: some View {
    Group {
      if let image {
        Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 200)
          .accessibilityLabel(label)
      } else if let error {
        VStack(alignment: .leading) {
          Text(error).fixedSize(horizontal: false, vertical: true)
          Button("Retry preview") { Task { await load() } }.frame(minHeight: 44)
        }
      } else {
        ProgressView("Loading cover preview…").frame(minHeight: 160)
      }
    }
    .task(id: url) { await load() }
  }

  private func load() async {
    image = nil
    error = nil
    do {
      let image = try await CoverPreviewLoader.shared.image(api: api, url: url)
      try Task.checkCancellation()
      self.image = image
    } catch {
      if !Task.isCancelled { self.error = error.localizedDescription }
    }
  }
}
