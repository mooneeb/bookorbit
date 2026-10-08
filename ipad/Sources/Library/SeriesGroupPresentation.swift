import SwiftUI

struct SeriesGroupSelection: Identifiable {
  let id: Int
  let name: String
  let libraryID: Int?

  init?(book: BookCard, libraryID: Int?) {
    guard book.collapsedSeries != nil, let seriesID = book.seriesId, seriesID > 0 else {
      return nil
    }
    id = seriesID
    name = book.seriesName ?? "Series"
    self.libraryID = libraryID
  }
}

struct SeriesGroupRow: View {
  let api: BookOrbitAPI
  let book: BookCard
  let openSeries: (BookCard) -> Void
  let openBook: (Int) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .top, spacing: 12) {
        SeriesGroupCovers(api: api, book: book, height: 64)
          .frame(width: 112)
        Button {
          openSeries(book)
        } label: {
          SeriesGroupSummary(book: book)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(book.seriesId == nil)
        .accessibilityLabel(book.seriesName ?? "Series")
        .accessibilityValue(book.seriesGroupCountText)
        .accessibilityHint("Open series contents")
        .accessibilityIdentifier("seriesGroup\(book.id)")
      }
      SeriesGroupActions(book: book, openSeries: openSeries, openBook: openBook)
    }
    .foregroundStyle(Color(uiColor: .label))
    .padding(.vertical, 8)
  }
}

struct SeriesGroupCard: View {
  let api: BookOrbitAPI
  let book: BookCard
  let openSeries: (BookCard) -> Void
  let openBook: (Int) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      SeriesGroupCovers(api: api, book: book, height: 160)
        .frame(maxWidth: .infinity)
      Button {
        openSeries(book)
      } label: {
        SeriesGroupSummary(book: book)
          .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(book.seriesId == nil)
      .accessibilityLabel(book.seriesName ?? "Series")
      .accessibilityValue(book.seriesGroupCountText)
      .accessibilityHint("Open series contents")
      .accessibilityIdentifier("seriesGroup\(book.id)")
      SeriesGroupActions(book: book, openSeries: openSeries, openBook: openBook)
    }
    .foregroundStyle(Color(uiColor: .label))
    .padding()
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
  }
}

struct SeriesGroupActions: View {
  let book: BookCard
  let openSeries: (BookCard) -> Void
  let openBook: (Int) -> Void

  var body: some View {
    Menu {
      if book.seriesId != nil {
        Button("Series contents") { openSeries(book) }
      }
      if let id = book.collapsedSeries?.firstVolumeBookId, id > 0 {
        Button("Open first volume") { openBook(id) }
          .accessibilityIdentifier("openSeriesFirstVolume\(book.id)")
      }
      if let id = book.collapsedSeries?.latestVolumeBookId, id > 0 {
        Button("Open latest volume") { openBook(id) }
          .accessibilityIdentifier("openSeriesLatestVolume\(book.id)")
      }
      if let id = book.collapsedSeries?.firstUnreadBookId, id > 0 {
        Button("Open first unread") { openBook(id) }
          .accessibilityIdentifier("openSeriesFirstUnread\(book.id)")
      }
    } label: {
      Label("Series actions", systemImage: "ellipsis.circle")
        .font(.body)
        .frame(minWidth: 44, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
    }
    .accessibilityIdentifier("seriesGroupActions\(book.id)")
  }
}

private struct SeriesGroupSummary: View {
  let book: BookCard

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Label(book.seriesName ?? "Series", systemImage: "books.vertical")
        .font(.headline)
      Text(book.seriesGroupCountText).font(.subheadline)
      if !book.authors.isEmpty {
        Text(book.authors.joined(separator: ", ")).font(.subheadline)
      }
    }
    .fixedSize(horizontal: false, vertical: true)
  }
}

struct SeriesGroupCovers: View {
  let api: BookOrbitAPI
  let book: BookCard
  let height: CGFloat

  private var coverIDs: [Int] {
    Array((book.collapsedSeries?.coverBookIds ?? []).prefix(4).filter { $0 > 0 })
  }

  var body: some View {
    HStack(spacing: 4) {
      if coverIDs.isEmpty {
        Image(systemName: "books.vertical")
          .font(.title)
          .frame(minWidth: 44, minHeight: height)
          .accessibilityHidden(true)
      } else {
        ForEach(coverIDs, id: \.self) { id in
          SeriesCoverThumbnail(
            api: api, bookID: id,
            version: version(for: id),
            height: height)
        }
      }
    }
  }

  private func version(for id: Int) -> String {
    if id == book.id { return book.coverVersion }
    return (book.collapsedSeries?.coverUpdatedAtByBookId?[String(id)] ?? nil) ?? ""
  }
}

private struct SeriesCoverThumbnail: View {
  let api: BookOrbitAPI
  let bookID: Int
  let version: String
  let height: CGFloat
  @State private var model = LibraryBookCoverModel()
  @State private var attempt = 0

  private struct LoadID: Hashable {
    let request: LibraryBookCoverRequest
    let attempt: Int
  }

  private var request: LibraryBookCoverRequest {
    LibraryBookCoverRequest(
      apiID: ObjectIdentifier(api), bookID: bookID, version: version, hasCover: true)
  }

  var body: some View {
    VStack(spacing: 4) {
      artwork
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .accessibilityHidden(true)
      if case .failed = model.state(for: request) {
        Button("Retry cover") { attempt += 1 }
          .font(.caption)
          .frame(minWidth: 44, minHeight: 44)
          .accessibilityLabel("Retry series cover")
          .accessibilityIdentifier("retrySeriesCover\(bookID)")
      }
    }
    .task(id: LoadID(request: request, attempt: attempt)) {
      await model.load(api: api, request: request)
    }
    .onDisappear { model.cancel() }
  }

  @ViewBuilder private var artwork: some View {
    switch model.state(for: request) {
    case .loaded(let image): Image(uiImage: image).resizable().scaledToFit()
    case .loading: ProgressView()
    case .absent: Image(systemName: "book.closed")
    case .failed: Image(systemName: "photo.badge.exclamationmark")
    }
  }
}

extension BookCard {
  var seriesGroupCountText: String {
    guard let info = collapsedSeries else { return "" }
    return "\(info.bookCount.formatted()) books, \(info.readCount.formatted()) read"
  }
}
