import Foundation
import Observation
import SwiftUI

@MainActor @Observable
final class KOReaderBookPickerModel {
  let api: BookOrbitAPI
  private(set) var books: [BookCard] = []
  private(set) var page = 0
  private(set) var total = 0
  private(set) var isBusy = false
  var search = ""
  var error: String?
  private var requestID = UUID()
  let pageSize = 40

  init(api: BookOrbitAPI) { self.api = api }
  var canNext: Bool { !isBusy && (page + 1) * pageSize < total }
  var canPrevious: Bool { !isBusy && page > 0 }

  func load(page: Int = 0) async {
    guard page >= 0 else { return }
    let request = UUID()
    requestID = request
    isBusy = true
    error = nil
    defer { if requestID == request { isBusy = false } }
    do {
      let query = BookQuery(
        filter: nil, sort: [.init(field: "title", dir: "asc")],
        pagination: .init(page: page, size: pageSize),
        q: search.trimmingCharacters(in: .whitespacesAndNewlines), collapseSeries: false,
        randomSeed: nil)
      let response: BooksPage = try await api.boundedJSONOnline(
        "books/query", method: "POST", body: JSONEncoder().encode(query))
      guard requestID == request else { return }
      guard response.items.count <= pageSize, response.total >= 0, response.page == page else {
        throw ConnectionError.invalidResponse
      }
      books = response.items
      total = response.total
      self.page = page
    } catch {
      if requestID == request, !Task.isCancelled { self.error = error.localizedDescription }
    }
  }
}

struct KOReaderBookPickerView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var model: KOReaderBookPickerModel
  @State private var selecting = false
  let title: String
  let selected: @MainActor (Int) async -> String?

  init(api: BookOrbitAPI, title: String, selected: @escaping @MainActor (Int) async -> String?) {
    _model = State(initialValue: KOReaderBookPickerModel(api: api))
    self.title = title
    self.selected = selected
  }

  var body: some View {
    NavigationStack {
      List {
        if let error = model.error {
          Text(error).foregroundStyle(.red).accessibilityIdentifier("koreaderLinkTargetError")
          Button("Retry", action: refresh)
        }
        TextField("Search your library", text: $model.search)
          .submitLabel(.search).onSubmit(search)
          .accessibilityIdentifier("koreaderLinkTargetSearch")
        Button("Search", action: search).accessibilityIdentifier("koreaderLinkTargetSearchSubmit")
        ForEach(model.books) { book in
          Button {
            select(book.id)
          } label: {
            VStack(alignment: .leading) {
              Text(book.title ?? "Untitled")
              Text(book.authors.joined(separator: ", "))
                .font(.caption).foregroundStyle(.secondary)
              if book.files.isEmpty {
                Text("No content file to link").font(.caption).foregroundStyle(.secondary)
              }
            }
          }
          .disabled(book.files.isEmpty)
          .accessibilityIdentifier("koreaderLinkTargetBook\(book.id)")
        }
        if model.books.isEmpty, !model.isBusy {
          Text("No books found.").foregroundStyle(.secondary)
        }
        HStack {
          Button("Previous", action: previous).disabled(!model.canPrevious)
          Spacer()
          Text("Page \(model.page + 1)").font(.caption)
          Spacer()
          Button("Next", action: next).disabled(!model.canNext)
        }
      }
      .disabled(model.isBusy || selecting)
      .overlay { if model.isBusy || selecting { ProgressView() } }
      .navigationTitle(title)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel", action: cancel).disabled(selecting)
        }
      }
      .task { await model.load() }
    }
  }
  private func refresh() { Task { await model.load(page: model.page) } }
  private func search() { Task { await model.load() } }
  private func previous() { Task { await model.load(page: model.page - 1) } }
  private func next() { Task { await model.load(page: model.page + 1) } }
  private func cancel() { dismiss() }
  private func select(_ id: Int) {
    guard !selecting else { return }
    selecting = true
    Task {
      let error = await selected(id)
      selecting = false
      if let error { model.error = error } else { dismiss() }
    }
  }
}
