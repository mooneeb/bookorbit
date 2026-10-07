import SwiftUI

struct EPUBSearchView: View {
  let model: EPUBReaderModel
  @State private var query = ""
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        Section {
          TextField("Search the whole book", text: $query).submitLabel(.search)
            .onSubmit(search).accessibilityIdentifier("epubSearchQuery")
            .disabled(model.isSearching)
          Button("Search book", action: search).frame(minHeight: 44)
            .disabled(
              model.isSearching || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || query.utf16.count > 128
            )
            .accessibilityIdentifier("epubSearchSubmit")
          if query.utf16.count > 128 { Text("Use 128 characters or fewer.") }
        }
        if model.isSearching { ProgressView("Searching book…") }
        if !model.searchQuery.isEmpty {
          Text("Searched \(model.searchedChapters) of \(model.info?.spine.count ?? 0) chapters")
            .accessibilityIdentifier("epubSearchProgress")
          Section("Matches in this batch") {
            if model.results.isEmpty {
              Text(
                model.searchComplete
                  ? "No more matches." : "No matches in these chapters. Continue searching.")
            }
            ForEach(model.results) { match in
              Button {
                open(match.id)
              } label: {
                Text(match.text).fixedSize(horizontal: false, vertical: true)
                  .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
              }.disabled(!model.canNavigate).accessibilityIdentifier("epubSearchMatch")
            }
            Button("Continue searching", action: next).frame(minHeight: 44)
              .disabled(model.isSearching || model.searchComplete).accessibilityIdentifier(
                "epubSearchNext")
          }
        }
        if let error = model.error { Text(error).accessibilityIdentifier("epubSearchError") }
      }
      .buttonStyle(.plain).navigationTitle("Search book")
      .toolbar {
        Button("Done", action: dismiss.callAsFunction).disabled(
          model.isSearching || model.isNavigating)
      }
    }
    .interactiveDismissDisabled(model.isSearching || model.isNavigating)
    .onDisappear { Task { await model.cancelSearch() } }
  }

  private func search() { Task { await model.search(query) } }
  private func next() { Task { await model.searchNext() } }
  private func open(_ cfi: String) {
    Task {
      await model.goToCFI(cfi)
      if model.error == nil { dismiss() }
    }
  }
}
