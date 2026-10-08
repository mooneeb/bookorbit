import SwiftUI
import UIKit

struct LibraryView: View {
  @Bindable var session: SessionModel
  @State private var library: LibraryModel
  @State private var selectedBook: Int?
  @State private var selectedSeries: SeriesGroupSelection?
  @State private var deletion: BookDeletionModel?
  @State private var deletionResult: String?
  @State private var presentation = "list"
  @State private var isCreatingCollection = false
  @State private var editingCollection: BookCollection?
  @State private var organization: OrganizationKind?
  @State private var showingDashboard = false
  @State private var showingScopes = false
  @State private var showingQuery = false
  @State private var showingSavedViews = false
  @State private var showingTableLayout = false
  @State private var showingTablePresets = false
  @State private var tableLayout = BookTableLayout.defaults
  @State private var tableDensity = BookTableDensity.comfortable
  @State private var tablePreferences: TablePresentationModel
  @State private var tablePresets: TablePresetModel
  @State private var tablePreferencesError: String?
  @State private var savedViews: SavedViewModel
  @State private var movement: BookMoveModel?
  @State private var moveNotice: String?
  @State private var moveRefresh: (bookID: Int, session: UUID)?

  init(session: SessionModel, api: BookOrbitAPI) {
    self.session = session
    _library = State(initialValue: LibraryModel(api: api, seriesCollapse: session.seriesCollapse))
    _savedViews = State(
      initialValue: SavedViewModel(serverURL: session.serverURL, userID: session.user?.id ?? 0))
    let preferences = TablePresentationModel(
      serverURL: session.serverURL, userID: session.user?.id ?? 0)
    _tablePreferences = State(initialValue: preferences)
    _tableLayout = State(initialValue: preferences.layout(at: BookLocation.all.storageKey))
    _tableDensity = State(initialValue: preferences.density)
    _tablePresets = State(
      initialValue: TablePresetModel(serverURL: session.serverURL, userID: session.user?.id ?? 0))
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
        CollectionSidebar(
          collections: library.collections, create: { isCreatingCollection = true },
          edit: { editingCollection = $0 }
        ) { collection in
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
          LibrarySearchField(text: $library.search) { Task { await library.searchBooks() } }
          SeriesCollapseControls(
            model: library.seriesCollapse, scope: library.location.seriesCollapseScope)
          if let moveNotice {
            Text(moveNotice).font(.body).fixedSize(horizontal: false, vertical: true)
              .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal)
              .accessibilityIdentifier("libraryMoveNotice")
          }
          HStack {
            if library.collapseSeries {
              Text("\(library.total.formatted()) books and series groups")
                .font(.subheadline).fixedSize(horizontal: false, vertical: true)
            } else {
              LibraryBookCountView(total: library.total)
            }
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
          if let deletionResult {
            Text(deletionResult).font(.body).fixedSize(horizontal: false, vertical: true)
              .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal)
              .accessibilityIdentifier("libraryDeletionResult")
          }
          if let error = library.error {
            ContentUnavailableView {
              Label("Could not load books", systemImage: "wifi.exclamationmark")
            } description: {
              Text(error)
            } actions: {
              Button("Try again", action: retryPage)
            }
          } else if presentation == "grid" {
            BookGrid(
              api: library.api, books: library.books, openSeries: openSeries,
              canDeleteBooks: session.user?.hasPermission(.libraryDeleteBooks) == true
                && !library.isBusy,
              delete: promptDelete,
              canMove: session.user?.hasPermission(.libraryEditMetadata) == true && !library.isBusy,
              move: promptMove
            ) { selectedBook = $0 }
            .id("\(session.serverURL).user.\(session.user?.id ?? 0)")
          } else if presentation == "table" {
            if !BookTableLayout.unavailable(tableLayout, customFields: library.tableCustomFields)
              .isEmpty
            {
              Text(
                "Some saved columns are unavailable at this library location. Their settings are preserved."
              )
              .font(.body).fixedSize(horizontal: false, vertical: true).padding(.horizontal)
              .accessibilityIdentifier("tableUnavailableColumns")
            }
            BookTableInteractionHost(
              library: library, user: session.user, select: { selectedBook = $0 },
              openSeriesGroup: openSeries, bookUnavailable: bookBecameUnavailable
            ) { renderer in
              BookTableView(
                books: library.books, layout: tableLayout, renderer: renderer, density: tableDensity
              ) { selectedBook = $0 }
            }
          } else {
            List(library.books) { book in
              if book.collapsedSeries != nil {
                SeriesGroupRow(
                  api: library.api, book: book, openSeries: openSeries, openBook: openBook)
              } else {
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
                  .contextMenu {
                    if session.user?.hasPermission(.libraryEditMetadata) == true {
                      Button("Move to library") { promptMove(book) }.disabled(library.isBusy)
                    }
                    if session.user?.hasPermission(.libraryDeleteBooks) == true {
                      Button("Delete book", role: .destructive) { promptDelete(book.id) }
                        .disabled(library.isBusy)
                    }
                  }
              }
            }
          }
          if library.isBusy { ProgressView("Loading books…").padding() }
          ViewThatFits(in: .horizontal) {
            HStack {
              presentationActions
              Spacer()
            }
            VStack(alignment: .leading) { presentationActions }
              .frame(maxWidth: .infinity, alignment: .leading)
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
        .toolbar {
          ToolbarItem(placement: .topBarTrailing) {
            Picker("Book presentation", selection: $presentation) {
              Label("List", systemImage: "list.bullet").tag("list")
              Label("Grid", systemImage: "square.grid.2x2").tag("grid")
              Label("Table", systemImage: "tablecells").tag("table")
            }.pickerStyle(.segmented)
          }
        }
        .alert(
          "Could not remember table settings",
          isPresented: Binding(
            get: { tablePreferencesError != nil },
            set: { if !$0 { tablePreferencesError = nil } })
        ) {
          Button("OK") { tablePreferencesError = nil }
        } message: {
          Text(tablePreferencesError ?? "")
        }
        .sheet(
          item: Binding(
            get: { selectedBook.map(BookSelection.init) }, set: { selectedBook = $0?.id }),
          onDismiss: {
            Task {
              await library.refreshAfterTableMutation()
              await library.collections.refresh()
            }
          }
        ) { selection in
          BookDetailView(
            api: library.api, bookID: selection.id,
            canEditMetadata: session.user?.hasPermission(.libraryEditMetadata) == true,
            canRead: session.user?.hasPermission(.libraryDownload) == true,
            canDeleteBooks: session.user?.hasPermission(.libraryDeleteBooks) == true,
            userID: session.user?.id ?? 0, bookUnavailable: bookBecameUnavailable)
        }
      }
    }
    .task { await library.load() }
    .onChange(of: library.collapseSeries) { Task { await library.seriesCollapseChanged() } }
    .sheet(item: $selectedSeries, onDismiss: { Task { await library.refreshAfterTableMutation() } })
    { group in
      SeriesGroupContentsView(
        api: library.api, group: group,
        canEditMetadata: session.user?.hasPermission(.libraryEditMetadata) == true,
        canRead: session.user?.hasPermission(.libraryDownload) == true,
        seriesCollapse: library.seriesCollapse,
        canDeleteBooks: session.user?.hasPermission(.libraryDeleteBooks) == true,
        userID: session.user?.id ?? 0)
    }
    .sheet(item: $deletion) { deletion in
      BookDeletionView(
        model: deletion,
        resolved: { outcome in
          bookBecameUnavailable(deletion.bookID, outcome)
          self.deletion = nil
        }, closed: deletionClosed)
    }
    .onChange(of: session.user?.id) {
      deletion?.detach()
      deletion = nil
      deletionResult = nil
      movement?.detach()
      movement = nil
      moveNotice = nil
      moveRefresh = nil
    }
    .sheet(item: $movement) { movement in
      BookMoveView(model: movement, closed: moveClosed)
    }
    .onChange(of: library.location.storageKey) { _, location in
      tableLayout = tablePreferences.layout(at: location)
    }
    .onChange(of: tableLayout) { _, layout in
      do { try tablePreferences.save(layout: layout, at: library.location.storageKey) } catch {
        tablePreferencesError = error.localizedDescription
      }
    }
    .onChange(of: tableDensity) { _, density in
      do { try tablePreferences.save(density: density) } catch {
        tablePreferencesError = error.localizedDescription
      }
    }
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
        model: savedViews, tablePresets: tablePresets, library: library,
        presentation: $presentation, layout: $tableLayout)
    }
    .sheet(isPresented: $showingTableLayout) {
      TableLayoutView(
        layout: $tableLayout, density: $tableDensity, customFields: library.tableCustomFields,
        fitWidth: fitTableColumn)
    }
    .sheet(isPresented: $showingTablePresets) {
      TablePresetsView(model: tablePresets, library: library, layout: $tableLayout)
    }
    .sheet(item: $organization) { kind in
      OrganizationDirectoryView(
        api: library.api, kind: kind, libraries: library.libraries,
        canEditMetadata: session.user?.hasPermission(.libraryEditMetadata) == true,
        canRead: session.user?.hasPermission(.libraryDownload) == true,
        seriesCollapse: library.seriesCollapse,
        canDeleteBooks: session.user?.hasPermission(.libraryDeleteBooks) == true,
        userID: session.user?.id ?? 0)
    }
    .sheet(isPresented: $isCreatingCollection) {
      CreateCollectionView(collections: library.collections) { collection in
        Task { await library.select(.collection(id: collection.id, name: collection.name)) }
      }
    }
    .sheet(item: $editingCollection) { collection in
      CollectionEditorView(
        collections: library.collections, collection: collection,
        onSaved: library.collectionUpdated,
        onDeleted: { id in Task { await library.collectionDeleted(id) } })
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

  private func openSeries(_ book: BookCard) {
    selectedSeries = SeriesGroupSelection(book: book, libraryID: library.location.seriesLibraryID)
  }

  private func openBook(_ id: Int) { selectedBook = id }

  private func promptDelete(_ bookID: Int) {
    guard let user = session.user, user.hasPermission(.libraryDeleteBooks), !library.isBusy,
      library.books.contains(where: { $0.id == bookID && $0.collapsedSeries == nil })
    else { return }
    deletion = BookDeletionModel(api: library.api, bookID: bookID, userID: user.id)
  }

  private func bookBecameUnavailable(_ bookID: Int, _ outcome: BookDeletionOutcome) {
    library.discardUnavailableBook(bookID)
    if selectedBook == bookID { selectedBook = nil }
    deletionResult = outcome.message
  }

  private func deletionClosed(_ deletion: BookDeletionModel) {
    guard deletion.didAttemptDeletion || deletion.outcome != nil else { return }
    Task {
      guard await deletion.belongsToCurrentSession() else { return }
      deletionResult =
        deletion.outcome?.message
        ?? "The deletion was not confirmed. Reload this book's status before trying again."
      await library.refreshAfterTableMutation(session: deletion.session)
      if library.error != nil {
        deletionResult = "Books could not be reloaded. Reload to reconcile the current page."
      }
    }
  }

  private func promptMove(_ book: BookCard) {
    guard let user = session.user, user.hasPermission(.libraryEditMetadata), !library.isBusy,
      book.collapsedSeries == nil,
      library.books.contains(where: { $0.id == book.id && $0.collapsedSeries == nil })
    else { return }
    movement = BookMoveModel(api: library.api, bookID: book.id, userID: user.id)
  }

  private func moveClosed(_ movement: BookMoveModel) {
    guard movement.needsStatusRefresh, let session = movement.session else { return }
    let notice =
      movement.message ?? "The move is unconfirmed. Reload the current page to check this book."
    Task {
      guard await movement.belongsToCurrentSession() else { return }
      moveNotice = notice
      moveRefresh = (movement.bookID, session)
      await library.refreshAfterMove(bookID: movement.bookID, session: session)
      if library.error == nil { moveRefresh = nil }
    }
  }

  private func retryPage() {
    Task {
      if let moveRefresh {
        await library.refreshAfterMove(bookID: moveRefresh.bookID, session: moveRefresh.session)
        if library.error == nil { self.moveRefresh = nil }
      } else {
        await library.refreshAfterTableMutation()
      }
    }
  }

  private func fitTableColumn(_ column: String) -> Double {
    let renderer = BookTableColumnRenderer(
      api: library.api, customFields: library.tableCustomFields,
      canEditMetadata: session.user?.hasPermission(.libraryEditMetadata) == true,
      canRead: session.user?.hasPermission(.libraryDownload) == true, action: { _ in })
    return max(
      BookTableLayout.minimumWidth(column),
      library.books.prefix(library.pageSize).map {
        Double(renderer.fittingWidth(book: $0, column: column))
      }.max()
        ?? BookTableLayout.width(column, layout: tableLayout))
  }

  @ViewBuilder private var presentationActions: some View {
    LibraryActionButton(
      title: String(localized: "Saved views"), identifier: "openSavedViews"
    ) { showingSavedViews = true }
    if presentation == "table" {
      Button("Table columns") { showingTableLayout = true }.frame(minHeight: 44)
        .accessibilityIdentifier("openTableColumns")
      Button("Column presets") { showingTablePresets = true }.frame(minHeight: 44)
        .accessibilityIdentifier("openTablePresets")
    }
  }
}

private struct LibrarySearchField: View {
  @Binding var text: String
  let submit: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
        ZStack(alignment: .topLeading) {
          if text.isEmpty {
            Text("Search books")
              .font(.body)
              .foregroundStyle(Color(uiColor: .label))
              .padding(.vertical, 8)
              .accessibilityHidden(true)
          }
          LibraryQueryInput(text: $text, submit: submit)
        }
      }
      .padding(.horizontal, 12)
      .background(
        Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
      if !text.isEmpty {
        Button(action: clear) {
          Label("Clear text", systemImage: "xmark.circle.fill")
            .labelStyle(.iconOnly)
            .font(.body)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
          .foregroundStyle(Color(uiColor: .label))
          .background(
            Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8)
          )
          .accessibilityIdentifier("clearLibrarySearch")
      }
    }.padding(.horizontal).padding(.vertical, 8)
  }

  private func clear() { text = "" }
}

private struct LibraryQueryInput: UIViewRepresentable {
  @Binding var text: String
  let submit: () -> Void

  func makeUIView(context: Context) -> UITextView {
    let field = UITextView()
    field.adjustsFontForContentSizeCategory = true
    field.textColor = .label
    field.backgroundColor = .clear
    field.returnKeyType = .search
    field.isScrollEnabled = false
    field.textContainer.lineFragmentPadding = 0
    field.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
    field.delegate = context.coordinator
    field.accessibilityLabel = "Search books"
    field.accessibilityIdentifier = "librarySearch"
    return field
  }

  func updateUIView(_ field: UITextView, context: Context) {
    context.coordinator.parent = self
    if field.text != text { field.text = text }
    field.font = UIFont.preferredFont(forTextStyle: .body, compatibleWith: field.traitCollection)
  }

  func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
    let width = proposal.width ?? 320
    let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    return CGSize(width: width, height: max(44, size.height))
  }

  func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

  @MainActor final class Coordinator: NSObject, UITextViewDelegate {
    var parent: LibraryQueryInput

    init(parent: LibraryQueryInput) { self.parent = parent }

    func textViewDidChange(_ textView: UITextView) { parent.text = textView.text }

    func textView(
      _ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String
    ) -> Bool {
      guard text == "\n" else { return true }
      parent.text = textView.text
      textView.resignFirstResponder()
      parent.submit()
      return false
    }
  }
}

private struct CollectionSidebar: View {
  @Bindable var collections: CollectionModel
  let create: () -> Void
  let edit: (BookCollection) -> Void
  let select: (BookCollection) -> Void

  var body: some View {
    Section {
      LibraryActionButton(
        title: String(localized: "New collection"), identifier: "newCollection", action: create
      )
      .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
      .padding(.vertical, 4)
      .foregroundStyle(Color(uiColor: .label))
      .listRowBackground(Color(uiColor: .systemBackground))
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
        VStack(alignment: .leading, spacing: 8) {
          Button {
            select(collection)
          } label: {
            HStack {
              CollectionIcon(value: collection.icon)
              Text(collection.name).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
              .contentShape(Rectangle())
          }
          .accessibilityLabel(collection.name)
          .accessibilityIdentifier("collectionSidebar\(collection.id)")
          Text(collection.isPublic ? "Shared collection" : "Private collection")
            .font(.body).fixedSize(horizontal: false, vertical: true)
          if collection.isOwner {
            Button("Edit collection") { edit(collection) }
              .font(.body).frame(minHeight: 44)
              .accessibilityLabel("Edit \(collection.name)")
              .accessibilityIdentifier("editCollection\(collection.id)")
          }
        }
        .foregroundStyle(Color(uiColor: .label))
        .disabled(collections.isMutating)
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
  let api: BookOrbitAPI
  let books: [BookCard]
  let openSeries: (BookCard) -> Void
  var canDeleteBooks = false
  var delete: (Int) -> Void = { _ in }
  let canMove: Bool
  let move: (BookCard) -> Void
  let select: (Int) -> Void

  var body: some View {
    ScrollView {
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), alignment: .top)], spacing: 16) {
        ForEach(books) { book in
          if book.collapsedSeries != nil {
            SeriesGroupCard(api: api, book: book, openSeries: openSeries, openBook: select)
          } else {
            LibraryBookCoverView(api: api, book: book, select: select)
              .contextMenu {
                if canMove { Button("Move to library") { move(book) } }
                if canDeleteBooks {
                  Button("Delete book", role: .destructive) { delete(book.id) }
                }
              }
          }
        }
      }.padding()
    }
  }
}

private struct LibraryActionButton: UIViewRepresentable {
  @Environment(\.isEnabled) private var isEnabled
  let title: String
  let identifier: String
  let action: () -> Void

  func makeCoordinator() -> Coordinator { Coordinator(action: action) }

  func makeUIView(context: Context) -> UIButton {
    let button = UIButton(type: .system)
    button.setTitle(title, for: .normal)
    button.setTitleColor(.label, for: .normal)
    button.backgroundColor = .systemBackground
    button.titleLabel?.font = .preferredFont(forTextStyle: .body)
    button.titleLabel?.adjustsFontForContentSizeCategory = true
    button.titleLabel?.numberOfLines = 0
    button.titleLabel?.lineBreakMode = .byWordWrapping
    button.contentHorizontalAlignment = .leading
    button.accessibilityIdentifier = identifier
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
