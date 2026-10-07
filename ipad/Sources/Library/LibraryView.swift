import SwiftUI
import UIKit

struct LibraryView: View {
  @Bindable var session: SessionModel
  @State private var library: LibraryModel
  @State private var selectedBook: Int?
  @State private var presentation = "list"
  @State private var isCreatingCollection = false
  @State private var organization: OrganizationKind?
  @State private var showingDashboard = false
  @State private var showingScopes = false
  @State private var showingQuery = false
  @State private var showingSavedViews = false
  @State private var showingTableLayout = false
  @State private var tableLayout = BookTableLayout.defaults
  @State private var savedViews: SavedViewModel

  init(session: SessionModel, api: BookOrbitAPI) {
    self.session = session
    _library = State(initialValue: LibraryModel(api: api))
    _savedViews = State(
      initialValue: SavedViewModel(serverURL: session.serverURL, userID: session.user?.id ?? 0))
  }

  var body: some View {
    NavigationSplitView {
      List {
        Button("Home") { showingDashboard = true }
          .accessibilityIdentifier("openDashboard")
        Button("All books") {
          Task { await library.select(.all) }
        }
        Button("Authors") { organization = .authors }
          .accessibilityIdentifier("browseAuthors")
        Button("Series") { organization = .series }
          .accessibilityIdentifier("browseSeries")
        Button("Smart scopes") { showingScopes = true }
          .accessibilityIdentifier("browseSmartScopes")
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
      .scrollContentBackground(.hidden)
      .background(Color(uiColor: .systemBackground))
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
            LibraryBookCountView(total: library.total)
            Spacer()
            Picker(
              "Sort books",
              selection: Binding(
                get: { library.sort }, set: { field in Task { await library.chooseSort(field) } })
            ) {
              Text("Title").tag("title")
              Text("Recently added").tag("addedAt")
              Text("Author").tag("author")
              if !["title", "addedAt", "author"].contains(library.sort) {
                Text(queryFieldLabel(library.sort)).tag(library.sort)
              }
            }
            Button {
              showingQuery = true
            } label: {
              Text("Filter and sort")
                .font(.body)
                .foregroundStyle(Color(uiColor: .label))
                .frame(minWidth: 44, minHeight: 44)
                .background(Color(uiColor: .systemBackground))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("libraryFilters")
          }
          .padding()
          .background(Color(uiColor: .systemBackground))
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
          } else if presentation == "table" {
            GeometryReader { geometry in
              ScrollView(.horizontal) {
                BookTableView(books: library.books, layout: tableLayout) { selectedBook = $0 }
                  .frame(width: tableWidth(geometry.size.width), height: geometry.size.height)
              }
            }
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
            SavedViewsButton { showingSavedViews = true }
            if presentation == "table" {
              Button("Table columns") { showingTableLayout = true }.frame(minHeight: 44)
                .accessibilityIdentifier(
                  "openTableColumns")
            }
            Spacer()
          }.font(.body).buttonStyle(.plain).foregroundStyle(Color(uiColor: .label)).frame(
            minHeight: 44
          ).padding(.horizontal)
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
              Label("Table", systemImage: "tablecells").tag("table")
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
            canEditMetadata: session.user?.hasPermission(.libraryEditMetadata) == true,
            canRead: session.user?.hasPermission(.libraryDownload) == true)
        }
      }
    }
    .task { await library.load() }
    .sheet(isPresented: $showingDashboard) {
      if let user = session.user {
        DashboardView(api: library.api, serverURL: session.serverURL, user: user)
      }
    }
    .sheet(isPresented: $showingScopes) {
      if let user = session.user {
        SmartScopeView(api: library.api, user: user) { scope in
          Task {
            await library.select(.scope(id: scope.id, name: scope.name, sort: scope.defaultSort))
          }
        }
      }
    }
    .sheet(isPresented: $showingQuery) { LibraryQueryView(library: library) }
    .sheet(isPresented: $showingSavedViews) {
      SavedViewsView(
        model: savedViews, library: library, presentation: $presentation, layout: $tableLayout)
    }
    .sheet(isPresented: $showingTableLayout) { TableLayoutView(layout: $tableLayout) }
    .sheet(item: $organization) { kind in
      OrganizationDirectoryView(
        api: library.api, kind: kind, libraries: library.libraries,
        canEditMetadata: session.user?.hasPermission(.libraryEditMetadata) == true,
        canRead: session.user?.hasPermission(.libraryDownload) == true)
    }
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

  private func tableWidth(_ available: CGFloat) -> CGFloat {
    let columns = BookTableLayout.visible(tableLayout)
    guard columns.contains(where: { tableLayout.columnWidths[$0] != nil }) else { return available }
    return max(
      available,
      CGFloat(columns.reduce(0) { $0 + (tableLayout.columnWidths[$1] ?? 180) }) + 32 + CGFloat(
        max(0, columns.count - 1)) * 12)
  }
}

private struct CollectionSidebar: View {
  @Bindable var collections: CollectionModel
  let create: () -> Void
  let select: (BookCollection) -> Void

  var body: some View {
    Section {
      Button("New collection", action: create)
        .padding(.vertical, 4)
        .foregroundStyle(Color(uiColor: .label))
        .listRowBackground(Color(uiColor: .systemBackground))
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
    } header: {
      Text("Collections")
        .foregroundStyle(Color(uiColor: .label))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .systemBackground))
    }
  }
}

private struct BookSelection: Identifiable { let id: Int }

private struct LibraryBookCountView: UIViewRepresentable {
  let total: Int

  func makeUIView(context: Context) -> UILabel {
    let label = UILabel()
    label.font = .preferredFont(forTextStyle: .subheadline)
    label.adjustsFontForContentSizeCategory = true
    label.textColor = .label
    label.backgroundColor = .systemBackground
    label.numberOfLines = 0
    return label
  }

  func updateUIView(_ label: UILabel, context: Context) {
    label.text = total == 1 ? "1 book" : "\(total.formatted()) books"
  }

  func sizeThatFits(_ proposal: ProposedViewSize, uiView: UILabel, context: Context) -> CGSize? {
    uiView.sizeThatFits(
      CGSize(width: proposal.width ?? .greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
  }
}

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

private struct SavedViewsButton: UIViewRepresentable {
  @Environment(\.isEnabled) private var isEnabled
  let action: () -> Void

  func makeCoordinator() -> Coordinator { Coordinator(action: action) }

  func makeUIView(context: Context) -> UIButton {
    let button = UIButton(type: .system)
    button.setTitle(String(localized: "Saved views"), for: .normal)
    button.setTitleColor(.label, for: .normal)
    button.backgroundColor = .systemBackground
    button.titleLabel?.font = .preferredFont(forTextStyle: .body)
    button.titleLabel?.adjustsFontForContentSizeCategory = true
    button.titleLabel?.numberOfLines = 0
    button.titleLabel?.lineBreakMode = .byWordWrapping
    button.contentHorizontalAlignment = .leading
    button.accessibilityIdentifier = "openSavedViews"
    button.addTarget(
      context.coordinator, action: #selector(Coordinator.activate), for: .touchUpInside)
    return button
  }

  func updateUIView(_ button: UIButton, context: Context) {
    context.coordinator.action = action
    button.isEnabled = isEnabled
  }

  func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIButton, context: Context) -> CGSize? {
    let titleSize =
      uiView.titleLabel?.sizeThatFits(
        CGSize(width: proposal.width ?? .greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
      ) ?? .zero
    return CGSize(width: max(44, titleSize.width), height: max(44, titleSize.height))
  }

  @MainActor final class Coordinator: NSObject {
    var action: () -> Void

    init(action: @escaping () -> Void) { self.action = action }

    @objc func activate() { action() }
  }
}
