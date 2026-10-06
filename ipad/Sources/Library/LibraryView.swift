import SwiftUI

struct LibraryView: View {
  @Bindable var session: SessionModel
  @State private var library: LibraryModel
  @State private var selectedBook: Int?
  @State private var presentation = "list"
  @State private var isCreatingCollection = false

  init(session: SessionModel, api: BookOrbitAPI) {
    self.session = session
    _library = State(initialValue: LibraryModel(api: api))
  }

  var body: some View {
    NavigationSplitView {
      List {
        Button("All books") {
          Task { await library.select(.all) }
        }
        ForEach(library.libraries) { item in
          Button(item.name) {
            Task { await library.select(.library(id: item.id, name: item.name)) }
          }
          .listRowBackground(Color(uiColor: .systemBackground))
        }
        CollectionSidebar(collections: library.collections, create: { isCreatingCollection = true })
        { collection in
          Task { await library.select(.collection(id: collection.id, name: collection.name)) }
        }
      }
      .buttonStyle(.plain)
      .font(.body)
      .foregroundStyle(.primary)
      .navigationTitle("Libraries")
      .safeAreaInset(edge: .bottom) {
        Button("Sign out") { Task { await session.signOut() } }
          .buttonStyle(.plain)
          .font(.body)
          .foregroundStyle(.primary)
          .frame(maxWidth: .infinity, minHeight: 44)
          .padding()
          .background(.background)
          .disabled(session.isBusy)
          .accessibilityIdentifier("signOut")
      }
    } detail: {
      NavigationStack {
        VStack(spacing: 0) {
          HStack {
            Group {
              if library.total == 1 {
                Text("1 book")
              } else {
                Text("\(library.total.formatted()) books")
              }
            }.font(.subheadline).foregroundStyle(.primary)
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
                }
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
              }.buttonStyle(.plain)
            }
          }
          if library.isBusy { ProgressView("Loading books…").padding() }
          HStack {
            if library.canGoBack {
              Button("Previous") { Task { await library.previousPage() } }
                .font(.body).foregroundStyle(.primary)
            }
            Spacer()
            Text("Page \(library.page + 1)").font(.body).foregroundStyle(.primary)
            Spacer()
            if library.canGoNext {
              Button("Next") { Task { await library.nextPage() } }
                .font(.body).foregroundStyle(.primary)
            }
          }.padding()
        }
        .navigationTitle(library.location.title)
        .searchable(text: $library.search, prompt: "Search books")
        .onSubmit(of: .search) { Task { await library.searchBooks() } }
        .toolbar {
          ToolbarItem(placement: .topBarTrailing) {
            Picker("Book presentation", selection: $presentation) {
              Label("List", systemImage: "list.bullet").tag("list")
              Label("Grid", systemImage: "square.grid.2x2").tag("grid")
            }.pickerStyle(.segmented)
          }
        }
        .sheet(
          item: Binding(
            get: { selectedBook.map(BookSelection.init) }, set: { selectedBook = $0?.id }),
          onDismiss: { Task { await library.refreshBooks() } }
        ) { selection in
          BookDetailView(
            api: library.api, bookID: selection.id,
            canEditMetadata: session.user?.hasPermission(.libraryEditMetadata) == true)
        }
      }
    }
    .task { await library.load() }
    .sheet(isPresented: $isCreatingCollection) {
      CreateCollectionView(collections: library.collections) { collection in
        Task { await library.select(.collection(id: collection.id, name: collection.name)) }
      }
    }
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

private struct CollectionSidebar: View {
  @Bindable var collections: CollectionModel
  let create: () -> Void
  let select: (BookCollection) -> Void

  var body: some View {
    Section("Collections") {
      Button("New collection", action: create)
        .padding(.vertical, 4)
        .accessibilityIdentifier("newCollection")
      if collections.total > 0 || !collections.search.isEmpty {
        HStack {
          Image(systemName: "magnifyingglass").accessibilityHidden(true)
          TextField("Find collection", text: $collections.search)
            .textFieldStyle(.roundedBorder)
            .onSubmit { Task { await collections.load() } }
            .accessibilityIdentifier("collectionSearch")
        }
      }
      ForEach(collections.items) { collection in
        Button(collection.name) { select(collection) }
          .listRowBackground(Color(uiColor: .systemBackground))
      }
      if collections.isBusy { ProgressView("Loading collections…") }
      if let error = collections.error {
        Text(error)
        Button("Try again") { Task { await collections.load() } }
      }
      if collections.canGoBack {
        Button("Previous collections") { Task { await collections.previousPage() } }
      }
      if collections.canGoNext {
        Button("Next collections") { Task { await collections.nextPage() } }
      }
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
