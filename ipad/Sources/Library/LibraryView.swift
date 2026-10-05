import SwiftUI

struct LibraryView: View {
  @Bindable var session: SessionModel
  @State private var library: LibraryModel
  @State private var selectedBook: Int?
  @State private var presentation = "list"

  init(session: SessionModel, api: BookOrbitAPI) {
    self.session = session
    _library = State(initialValue: LibraryModel(api: api))
  }

  var body: some View {
    NavigationSplitView {
      List {
        Button("All books") {
          library.libraryID = nil
          Task { await library.searchBooks() }
        }
        ForEach(library.libraries) { item in
          Button(item.name) {
            library.libraryID = item.id
            Task { await library.searchBooks() }
          }
        }
      }
      .navigationTitle("Libraries")
    } detail: {
      NavigationStack {
        VStack(spacing: 0) {
          HStack {
            Text("\(library.total.formatted()) books").font(.subheadline).foregroundStyle(
              .secondary)
            Spacer()
            Picker("Sort books", selection: $library.sort) {
              Text("Title").tag("title")
              Text("Recently added").tag("addedAt")
              Text("Author").tag("author")
            }
            .onChange(of: library.sort) { Task { await library.searchBooks() } }
          }.padding()
          if let error = library.error {
            ContentUnavailableView {
              Label("Could not load books", systemImage: "wifi.exclamationmark")
            } description: {
              Text(error)
            } actions: {
              Button("Try again") { Task { await library.searchBooks() } }
            }
          } else if presentation == "grid" {
            BookGrid(books: library.books) { selectedBook = $0 }
          } else {
            List(library.books) { book in
              Button {
                selectedBook = book.id
              } label: {
                VStack(alignment: .leading, spacing: 5) {
                  Text(book.title ?? "Untitled book").font(.headline)
                  Text(book.authors.joined(separator: ", ")).font(.subheadline).foregroundStyle(
                    .secondary)
                }.padding(.vertical, 8)
              }.buttonStyle(.plain)
            }
          }
          if library.isBusy { ProgressView("Loading books…").padding() }
          HStack {
            Button("Previous") { Task { await library.previousPage() } }.disabled(
              !library.canGoBack)
            Spacer()
            Text("Page \(library.page + 1)").foregroundStyle(.secondary)
            Spacer()
            Button("Next") { Task { await library.nextPage() } }.disabled(!library.canGoNext)
          }.padding()
        }
        .navigationTitle("Books")
        .searchable(text: $library.search, prompt: "Search books")
        .onSubmit(of: .search) { Task { await library.searchBooks() } }
        .toolbar {
          ToolbarItem(placement: .primaryAction) {
            Button("Sign out") { Task { await session.signOut() } }
              .disabled(session.isBusy)
              .accessibilityIdentifier("signOut")
          }
          ToolbarItem(placement: .topBarTrailing) {
            Picker("Book presentation", selection: $presentation) {
              Label("List", systemImage: "list.bullet").tag("list")
              Label("Grid", systemImage: "square.grid.2x2").tag("grid")
            }.pickerStyle(.segmented)
          }
        }
        .sheet(
          item: Binding(
            get: { selectedBook.map(BookSelection.init) }, set: { selectedBook = $0?.id })
        ) { selection in
          BookDetailView(api: library.api, bookID: selection.id)
        }
      }
    }
    .task { await library.load() }
    .alert(
      "Could not sign out",
      isPresented: Binding(get: { session.error != nil }, set: { if !$0 { session.error = nil } })
    ) {
      Button("OK") { session.error = nil }
    } message: {
      Text(session.error ?? "")
    }
  }
}

private struct BookSelection: Identifiable { let id: Int }

private struct BookGrid: View {
  let books: [BookCard]
  let select: (Int) -> Void

  var body: some View {
    ScrollView {
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 180))]) {
        ForEach(books) { book in
          Button {
            select(book.id)
          } label: {
            VStack(alignment: .leading, spacing: 8) {
              Image(systemName: "book.closed").font(.largeTitle)
                .frame(maxWidth: .infinity, minHeight: 120)
              Text(book.title ?? "Untitled book").font(.headline)
              Text(book.authors.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
            }.padding().frame(maxWidth: .infinity, alignment: .leading)
              .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
          }.buttonStyle(.plain)
        }
      }.padding()
    }
  }
}
