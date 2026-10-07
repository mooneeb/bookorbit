import Foundation
import Observation

struct BookTableDestination: Identifiable {
  enum Kind {
    case metadata, coverEditor
    case reader(fileID: Int)
  }
  let id = UUID()
  let bookID: Int
  let kind: Kind
}

struct BookTableOrganizationDestination: Identifiable {
  let id = UUID()
  let kind: OrganizationKind
  let name: String
  var selection: OrganizationSelection?
}

@MainActor @Observable
final class BookTableInteractionModel {
  let library: LibraryModel
  var editor: BookTableCellEditorModel?
  var cover: BookCard?
  var collectionBook: BookCard?
  var quickBook: BookCard?
  var destination: BookTableDestination?
  var organization: BookTableOrganizationDestination?
  private(set) var isBusy = false
  private(set) var error: String?
  private(set) var message: String?
  private var retryAction: BookTableAction?
  private var refreshPending = false
  private var pendingCoverEditor: BookTableDestination?
  private var pendingBookDetails: Int?

  init(library: LibraryModel) { self.library = library }

  func handle(_ action: BookTableAction, user: AuthUser?, select: (Int) -> Void) {
    guard let user, !isBusy else { return }
    let canEdit = user.hasPermission(.libraryEditMetadata)
    let canRead = user.hasPermission(.libraryDownload)
    switch action {
    case .edit(let book, let column):
      guard canEdit, BookTableColumnSchema.canEdit(book, definition: column) else { return }
      editor = BookTableCellEditorModel(api: library.api, book: book, column: column)
    case .toggleLock(let book, let field):
      guard canEdit, MetadataVocabulary.lockFields.contains(field) else { return }
      Task { await mutate(action, book: book) }
    case .toggleAllLocks(let book):
      guard canEdit else { return }
      Task { await mutate(action, book: book) }
    case .details(let book): select(book.id)
    case .quickView(let book): quickBook = book
    case .read(let book, let fileID):
      guard canRead, BookTableColumnSchema.contentFiles(book).contains(where: { $0.id == fileID })
      else { return }
      destination = .init(bookID: book.id, kind: .reader(fileID: fileID))
    case .cover(let book): cover = book
    case .editMetadata(let book):
      guard canEdit else { return }
      destination = .init(bookID: book.id, kind: .metadata)
    case .refreshMetadata(let book):
      guard canEdit else { return }
      Task { await mutate(action, book: book) }
    case .collections(let book): collectionBook = book
    case .authors(let name): organization = .init(kind: .authors, name: name)
    case .series(let id, let name):
      organization = .init(kind: .series, name: name, selection: .init(id: id, name: name))
    case .quickFilter(let rule):
      Task {
        var filter = library.filter ?? GroupRule(type: "group", join: "AND", rules: [])
        if filter.join == "AND" {
          filter.rules.append(.rule(rule))
        } else {
          filter = .init(type: "group", join: "AND", rules: [.group(filter), .rule(rule)])
        }
        await library.apply(filter: filter, sort: currentSort)
      }
    case .sort(let field):
      Task {
        if library.sort == field {
          library.descending.toggle()
          await library.searchBooks()
        } else {
          await library.chooseSort(field)
        }
      }
    case .sortDirection(let field, let descending):
      Task {
        await library.apply(
          filter: library.filter, sort: [SortSpec(field: field, dir: descending ? "desc" : "asc")])
      }
    case .clearSort(let field):
      Task {
        let sorts = currentSort.filter { $0.field != field }
        await library.apply(
          filter: library.filter,
          sort: sorts.isEmpty ? [SortSpec(field: "title", dir: "asc")] : sorts)
      }
    }
  }

  func retry(user: AuthUser?, select: (Int) -> Void) {
    if refreshPending {
      Task { await refresh() }
    } else if let retryAction {
      handle(retryAction, user: user, select: select)
    }
  }

  func didSaveCell() { Task { await refresh() } }
  func destinationClosed() { Task { await refresh() } }
  func editCovers(bookID: Int) {
    pendingCoverEditor = .init(bookID: bookID, kind: .coverEditor)
    cover = nil
  }
  func coverClosed() {
    if let pendingCoverEditor {
      destination = pendingCoverEditor
      self.pendingCoverEditor = nil
    }
  }
  func openQuickBookDetails(_ bookID: Int) {
    pendingBookDetails = bookID
    quickBook = nil
  }
  func quickViewClosed(select: (Int) -> Void) {
    if let pendingBookDetails {
      select(pendingBookDetails)
      self.pendingBookDetails = nil
    }
  }
  func collectionSaved(name: String, included: Bool) {
    message = included ? "Added to \(name)" : "Removed from \(name)"
    Task {
      await library.collections.refresh()
      await refresh()
    }
  }

  private func mutate(_ action: BookTableAction, book: BookCard) async {
    guard !isBusy else { return }
    isBusy = true
    error = nil
    message = nil
    retryAction = action
    defer { isBusy = false }
    do {
      let saved: BookDetail
      switch action {
      case .toggleLock(_, let field):
        let locks =
          book.lockedFields.contains(field)
          ? book.lockedFields.filter { $0 != field } : book.lockedFields + [field]
        saved = try await library.api.boundedJSON(
          "books/\(book.id)/metadata-and-locks", method: "PATCH",
          body: JSONEncoder().encode(BookMetadataAndLocksUpdatePayload(lockedFields: locks)))
      case .toggleAllLocks:
        let all = Set(MetadataVocabulary.lockFields).isSubset(of: Set(book.lockedFields))
        saved = try await library.api.boundedJSON(
          "books/\(book.id)/metadata-and-locks", method: "PATCH",
          body: JSONEncoder().encode(
            BookMetadataAndLocksUpdatePayload(
              lockedFields: all ? [] : MetadataVocabulary.lockFields)))
      case .refreshMetadata:
        saved = try await library.api.boundedJSON(
          "books/\(book.id)/refresh-metadata", method: "POST")
      default: return
      }
      guard saved.id == book.id else { throw ConnectionError.invalidResponse }
      retryAction = nil
      message = "Saved changes to \(saved.title ?? "Untitled book")."
      await refresh()
    } catch {
      self.error =
        "The change could not be confirmed. Retry when connected. \(error.localizedDescription)"
    }
  }

  private func refresh() async {
    await library.refreshAfterTableMutation()
    refreshPending = library.error != nil
    if refreshPending {
      error = "Changes saved. The table could not be reloaded. Retry to reload it."
    } else {
      error = nil
    }
  }

  private var currentSort: [SortSpec] {
    [SortSpec(field: library.sort, dir: library.descending ? "desc" : "asc")]
      + library.secondarySort
  }
}
