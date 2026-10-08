import SwiftUI

struct OrganizationDetailView: View {
  let canEditMetadata: Bool
  let canRead: Bool
  let canDeleteBooks: Bool
  let userID: Int
  @State private var model: OrganizationDetailModel
  @State private var selectedBook: OrganizationSelection?
  @State private var selectedSeries: SeriesGroupSelection?

  init(
    api: BookOrbitAPI, kind: OrganizationKind, selection: OrganizationSelection,
    libraryID: Int?, canEditMetadata: Bool, canRead: Bool,
    seriesCollapse: SeriesCollapsePreferenceModel? = nil, canDeleteBooks: Bool = false,
    userID: Int = 0
  ) {
    self.canEditMetadata = canEditMetadata
    self.canRead = canRead
    self.canDeleteBooks = canDeleteBooks
    self.userID = userID
    _model = State(
      initialValue: OrganizationDetailModel(
        api: api, kind: kind, selection: selection, libraryID: libraryID,
        seriesCollapse: seriesCollapse))
  }

  var body: some View {
    VStack(spacing: 0) {
      if model.kind == .authors {
        SeriesCollapseControls(model: model.seriesCollapse, scope: .authors)
      }
      if let error = model.error {
        ContentUnavailableView {
          Label("Could not load books", systemImage: "wifi.exclamationmark")
        } description: {
          Text(error)
        } actions: {
          Button("Try again") { Task { await model.refreshBooks() } }
        }
      } else {
        List {
          if let author = model.author {
            Section("About \(author.name)") {
              if let description = author.description, !description.isEmpty { Text(description) }
              if let birth = author.birthDate ?? author.birthYear.map(String.init) {
                Text("Born: \(birth)")
              }
              if let death = author.deathDate ?? author.deathYear.map(String.init) {
                Text("Died: \(death)")
              }
              if !author.genres.isEmpty { Text("Genres: \(author.genres.joined(separator: ", "))") }
              if !author.influences.isEmpty {
                Text("Influences: \(author.influences.joined(separator: ", "))")
              }
              if let raw = author.website, let url = URL(string: raw),
                ["http", "https"].contains(url.scheme?.lowercased() ?? "")
              {
                Link("Author website", destination: url)
              }
            }
          }
          if let series = model.series {
            Section("Series") {
              Text(series.authors.joined(separator: ", "))
              Text("\(series.readCount) of \(series.bookCount) books read")
              if let expected = series.expectedBookCount { Text("\(expected) expected volumes") }
              if !series.possibleGaps.isEmpty {
                Text(
                  "Possible missing volumes: \(series.possibleGaps.map { String($0) }.joined(separator: ", "))"
                )
              }
            }
          }
          Section("Books") {
            ForEach(model.books) { book in
              if book.collapsedSeries != nil {
                SeriesGroupRow(
                  api: model.api, book: book, openSeries: openSeries, openBook: openBook)
              } else {
                Button {
                  selectedBook = OrganizationSelection(
                    id: book.id, name: book.title ?? "Untitled book")
                } label: {
                  VStack(alignment: .leading, spacing: 6) {
                    Text(book.title ?? "Untitled book").font(.headline)
                    Text(book.authors.joined(separator: ", ")).font(.subheadline)
                    Text(
                      book.files.map { $0.format?.uppercased() ?? "Unknown format" }.joined(
                        separator: ", ")
                    )
                    .font(.subheadline)
                  }
                  .foregroundStyle(Color(uiColor: .label))
                  .padding(.vertical, 8)
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("organizationBook\(book.id)")
              }
            }
            if model.books.isEmpty && !model.isBusy { Text("No accessible books") }
          }
        }
      }
      if model.isBusy { ProgressView("Loading books…").padding() }
      HStack {
        Spacer()
        Menu("Sort books") {
          Picker("Sort by", selection: $model.sort) {
            Text("Title").tag("title")
            Text("Recently added").tag("addedAt")
            if model.kind == .authors {
              Text("Publication year").tag("publishedYear")
            } else {
              Text("Volume order").tag("seriesIndex")
            }
          }
          Toggle("Descending", isOn: $model.descending)
        }
        .frame(minHeight: 44)
      }
      .font(.body)
      .buttonStyle(.plain)
      .foregroundStyle(Color(uiColor: .label))
      .padding(.horizontal)
      .background(Color(uiColor: .systemBackground))
      OrganizationPagingView(
        page: model.page, total: model.total,
        canGoBack: model.canGoBack, canGoNext: model.canGoNext,
        previous: { Task { await model.previousPage() } },
        next: { Task { await model.nextPage() } })
    }
    .navigationTitle(model.selection.name)
    .onChange(of: model.sort) { Task { await model.load() } }
    .onChange(of: model.descending) { Task { await model.load() } }
    .onChange(of: model.collapseSeries) { Task { await model.seriesCollapseChanged() } }
    .task { await model.load() }
    .sheet(
      item: $selectedBook, onDismiss: { Task { await model.refreshAfterBookMutation() } },
      content: { book in
        BookDetailView(
          api: model.api, bookID: book.id, canEditMetadata: canEditMetadata, canRead: canRead,
          canDeleteBooks: canDeleteBooks, userID: userID,
          bookUnavailable: { bookID, _ in
            model.discardUnavailableBook(bookID)
            if selectedBook?.id == bookID { selectedBook = nil }
          })
      }
    )
    .sheet(
      item: $selectedSeries, onDismiss: { Task { await model.refreshAfterBookMutation() } },
      content: { group in
        SeriesGroupContentsView(
          api: model.api, group: group, canEditMetadata: canEditMetadata, canRead: canRead,
          seriesCollapse: model.seriesCollapse, canDeleteBooks: canDeleteBooks, userID: userID)
      })
  }

  private func openSeries(_ book: BookCard) {
    selectedSeries = SeriesGroupSelection(book: book, libraryID: model.libraryID)
  }

  private func openBook(_ id: Int) {
    selectedBook = OrganizationSelection(id: id, name: "Book")
  }
}
