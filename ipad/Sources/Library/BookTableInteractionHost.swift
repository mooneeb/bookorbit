import SwiftUI

struct BookTableInteractionHost<Content: View>: View {
  @Bindable var library: LibraryModel
  let user: AuthUser?
  let select: @MainActor (Int) -> Void
  let openSeriesGroup: @MainActor (BookCard) -> Void
  var bookUnavailable: (Int, BookDeletionOutcome) -> Void = { _, _ in }
  let content: (BookTableColumnRenderer) -> Content
  @State private var interactions: BookTableInteractionModel

  init(
    library: LibraryModel, user: AuthUser?, select: @escaping @MainActor (Int) -> Void,
    openSeriesGroup: @escaping @MainActor (BookCard) -> Void = { _ in },
    bookUnavailable: @escaping (Int, BookDeletionOutcome) -> Void = { _, _ in },
    @ViewBuilder content: @escaping (BookTableColumnRenderer) -> Content
  ) {
    self.library = library
    self.user = user
    self.select = select
    self.openSeriesGroup = openSeriesGroup
    self.bookUnavailable = bookUnavailable
    self.content = content
    _interactions = State(initialValue: BookTableInteractionModel(library: library))
  }

  private var renderer: BookTableColumnRenderer {
    BookTableColumnRenderer(
      api: library.api, customFields: library.tableCustomFields,
      canEditMetadata: user?.hasPermission(.libraryEditMetadata) == true,
      canRead: user?.hasPermission(.libraryDownload) == true,
      canDeleteBooks: user?.hasPermission(.libraryDeleteBooks) == true,
      isBusy: interactions.isBusy || library.isBusy, sort: library.sort,
      descending: library.descending, openSeriesGroup: openSeriesGroup, openSeriesBook: select,
      action: { interactions.handle($0, user: user, select: select) })
  }

  var body: some View {
    VStack(spacing: 0) {
      if let error = library.customFieldsError {
        HStack {
          Text("Custom columns could not be loaded. \(error)").font(.footnote)
            .fixedSize(horizontal: false, vertical: true)
          Button("Retry custom columns") { Task { await library.loadCustomFields() } }
            .frame(minHeight: 44).disabled(library.isLoadingCustomFields)
            .accessibilityIdentifier("tableCustomFieldsRetry")
        }.padding(.horizontal)
      }
      if let error = interactions.error {
        HStack {
          Label(error, systemImage: "exclamationmark.triangle")
            .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier(
              "tableActionError")
          Button("Try again") { interactions.retry(user: user, select: select) }
            .frame(minHeight: 44).disabled(interactions.isBusy || library.isBusy)
            .accessibilityIdentifier("tableActionRetry")
        }.padding()
      } else if let message = interactions.message {
        Text(message).font(.footnote).fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal)
          .accessibilityIdentifier("tableActionResult")
      }
      if interactions.isBusy { ProgressView("Saving table changes…").padding() }
      content(renderer)
    }
    .foregroundStyle(.primary)
    .onChange(of: user?.id) { _, _ in
      interactions.moveSessionChanged()
      interactions.deletion?.detach()
      interactions.deletion = nil
    }
    .sheet(item: $interactions.movement) { movement in
      BookMoveView(model: movement, closed: interactions.moveClosed)
    }
    .sheet(item: $interactions.editor) { editor in
      BookTableCellEditorView(model: editor, saved: interactions.didSaveCell)
    }
    .sheet(item: $interactions.collectionBook) { book in
      CollectionPickerView(api: library.api, bookID: book.id) { collection, included in
        interactions.collectionSaved(name: collection.name, included: included)
      }
    }
    .sheet(item: $interactions.cover, onDismiss: interactions.coverClosed) { book in
      BookTableCoverPreviewView(
        api: library.api, book: book,
        canEditMetadata: user?.hasPermission(.libraryEditMetadata) == true
      ) {
        interactions.editCovers(bookID: book.id)
      }
    }
    .sheet(item: $interactions.organization) { destination in
      BookTableOrganizationView(
        api: library.api, destination: destination, user: user,
        libraryID: library.location.seriesLibraryID, seriesCollapse: library.seriesCollapse)
    }
    .sheet(
      item: $interactions.quickBook, onDismiss: { interactions.quickViewClosed(select: select) }
    ) { book in
      BookTableQuickView(book: book) { interactions.openQuickBookDetails(book.id) }
    }
    .fullScreenCover(item: $interactions.destination, onDismiss: interactions.destinationClosed) {
      destination in
      BookTableDestinationView(api: library.api, destination: destination)
    }
    .sheet(item: $interactions.deletion) { deletion in
      BookDeletionView(
        model: deletion,
        resolved: { outcome in
          interactions.didResolveDeletion(bookID: deletion.bookID, outcome: outcome)
          bookUnavailable(deletion.bookID, outcome)
        }, closed: interactions.deletionClosed)
    }
  }
}
