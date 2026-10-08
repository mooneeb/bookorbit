import SwiftUI

struct BookTableCoverPreviewView: View {
  let api: BookOrbitAPI
  let book: BookCard
  let canEditMetadata: Bool
  let edit: () -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var medium: CoverMedium
  @State private var image: UIImage?
  @State private var error: String?
  @State private var loading = false
  @State private var attempt = 0
  private var media: [CoverMedium] {
    let files = BookTableColumnSchema.contentFiles(book)
    let audio = files.contains {
      AudioStreamFormat.mimeTypes[$0.format?.lowercased() ?? ""] != nil
        || $0.mediaOverlay?.available == true
    }
    let ebook = files.contains { AudioStreamFormat.mimeTypes[$0.format?.lowercased() ?? ""] == nil }
    return (ebook ? [CoverMedium.ebook] : []) + (audio ? [CoverMedium.audio] : [])
  }

  init(api: BookOrbitAPI, book: BookCard, canEditMetadata: Bool, edit: @escaping () -> Void) {
    self.api = api
    self.book = book
    self.canEditMetadata = canEditMetadata
    self.edit = edit
    let isAudio =
      AudioStreamFormat.mimeTypes[
        BookTableColumnSchema.primaryFile(book)?.format?.lowercased() ?? ""] != nil
    _medium = State(initialValue: isAudio ? .audio : .ebook)
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(spacing: 20) {
          Text(book.title ?? "Untitled book").font(.headline)
          if media.count > 1 {
            Picker("Cover", selection: $medium) {
              ForEach(media) { value in Text(value.label).tag(value) }
            }.pickerStyle(.segmented)
          }
          if let image {
            Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 600)
              .accessibilityLabel("\(medium.label) for \(book.title ?? "Untitled book")")
              .accessibilityIdentifier("tableCoverPreview")
          } else if loading {
            ProgressView("Loading cover…")
          } else if let error {
            Label(error, systemImage: "photo.badge.exclamationmark")
              .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier(
                "tableCoverError")
            Button("Retry cover") { attempt += 1 }.frame(minHeight: 44)
              .accessibilityIdentifier("tableCoverRetry")
          }
          if canEditMetadata {
            Button("Edit covers", action: edit).frame(minHeight: 44)
              .accessibilityIdentifier("tableEditCovers")
          }
        }.padding()
      }
      .navigationTitle("Cover preview")
      .toolbar { Button("Done", action: dismiss.callAsFunction) }
    }
    .task(id: "\(medium.rawValue).\(attempt)") {
      loading = true
      image = nil
      error = nil
      defer { loading = false }
      do {
        let namespace = try await api.imageNamespace()
        let result = try await CoverPreviewLoader.shared.image(
          api: api, book: book, medium: medium, namespace: namespace)
        try Task.checkCancellation()
        guard try await api.imageNamespace() == namespace else {
          throw ConnectionError.expiredSession
        }
        image = result
      } catch {
        if !Task.isCancelled { self.error = error.localizedDescription }
      }
    }
  }
}
