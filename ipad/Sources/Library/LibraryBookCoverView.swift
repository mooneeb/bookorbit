import SwiftUI

struct LibraryBookCoverView: View {
  let api: BookOrbitAPI
  let book: BookCard
  let select: (Int) -> Void
  @State private var model = LibraryBookCoverModel()
  @State private var attempt = 0

  private struct LoadID: Hashable {
    let request: LibraryBookCoverRequest
    let attempt: Int
  }

  private var request: LibraryBookCoverRequest {
    LibraryBookCoverRequest(
      apiID: ObjectIdentifier(api), bookID: book.id, version: book.coverVersion,
      hasCover: book.hasCover)
  }

  private var title: String { book.title ?? "Untitled book" }
  private var state: LibraryBookCoverState { model.state(for: request) }

  private var coverStatus: String {
    switch state {
    case .absent: "No cover available"
    case .loading: "Loading cover"
    case .loaded: "Cover available"
    case .failed: "Could not load cover"
    }
  }

  private var hasFailed: Bool {
    if case .failed = state { return true }
    return false
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Button(action: openBook) {
        VStack(alignment: .leading, spacing: 8) {
          artwork
            .frame(maxWidth: .infinity)
            .frame(height: 200)
            .background(
              Color(uiColor: .tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 8)
            )
            .accessibilityHidden(true)
          Text(title)
            .font(.headline)
            .fixedSize(horizontal: false, vertical: true)
          if !book.authors.isEmpty {
            Text(book.authors.joined(separator: ", "))
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(([title] + book.authors).joined(separator: ", "))
      .accessibilityValue(coverStatus)
      .accessibilityHint("Open book")
      .accessibilityIdentifier("libraryBook\(book.id)")
      if hasFailed {
        Text("Could not load cover")
          .font(.caption)
          .fixedSize(horizontal: false, vertical: true)
        Button("Retry cover", action: retry)
          .buttonStyle(.plain)
          .font(.body)
          .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
          .contentShape(Rectangle())
          .accessibilityLabel("Retry cover for \(title)")
          .accessibilityIdentifier("retryLibraryCover\(book.id)")
      }
    }
    .foregroundStyle(.primary)
    .padding()
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    .task(id: LoadID(request: request, attempt: attempt)) {
      await model.load(api: api, request: request)
    }
    .onDisappear { model.cancel() }
  }

  @ViewBuilder private var artwork: some View {
    switch state {
    case .loaded(let image):
      Image(uiImage: image).resizable().scaledToFit()
    case .loading:
      ProgressView("Loading cover…")
        .font(.caption)
    case .absent:
      VStack(spacing: 8) {
        Image(systemName: "book.closed").font(.largeTitle)
        Text("No cover").font(.caption)
      }
    case .failed:
      Image(systemName: "photo.badge.exclamationmark").font(.largeTitle)
    }
  }

  private func openBook() { select(book.id) }
  private func retry() { attempt += 1 }
}
