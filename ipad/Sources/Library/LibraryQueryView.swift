import SwiftUI

struct LibraryQueryView: View {
  let library: LibraryModel
  @Environment(\.dismiss) private var dismiss
  @State private var filter: FilterDraft
  @State private var sorts: [SortSpec]
  @State private var error: String?
  @State private var isSaving = false

  init(library: LibraryModel) {
    self.library = library
    _filter = State(initialValue: .group(library.filter))
    _sorts = State(
      initialValue: [SortSpec(field: library.sort, dir: library.descending ? "desc" : "asc")]
        + library.secondarySort)
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        Form {
          Section("Filter books") { FilterEditor(draft: $filter) }
          Section("Sort books") {
            ForEach(sorts.indices, id: \.self) { index in
              HStack {
                Picker("Sort \(index + 1)", selection: $sorts[index].field) {
                  ForEach(SortVocabulary.fields.filter { $0 != "collectionOrder" }, id: \.self) {
                    field in
                    Text(queryFieldLabel(field)).tag(field)
                  }
                }
                Picker("Direction", selection: $sorts[index].dir) {
                  Text("Ascending").tag("asc")
                  Text("Descending").tag("desc")
                }
                if sorts.count > 1 {
                  Button("Remove", role: .destructive) { sorts.remove(at: index) }
                    .font(.body).frame(minHeight: 44)
                }
              }
            }
            Button("Add sort") { sorts.append(SortSpec(field: "title", dir: "asc")) }
              .font(.body).frame(minHeight: 44).disabled(sorts.count >= 5)
          }
          if let error { Text(error).font(.body).foregroundStyle(Color(uiColor: .label)) }
        }.disabled(isSaving)
        HStack {
          Button("Cancel", action: dismiss.callAsFunction)
          Button("Clear filters") { filter = .group() }
          Spacer()
          Button("Apply") { Task { await apply() } }
            .accessibilityIdentifier("applyLibraryFilters")
        }.font(.body).frame(minHeight: 44).padding().disabled(isSaving)
      }.navigationTitle("Filter and sort")
        .interactiveDismissDisabled(isSaving)
    }
  }

  private func apply() async {
    guard !isSaving else { return }
    do {
      let query = try filter.filter()
      isSaving = true
      defer { isSaving = false }
      await library.apply(filter: query, sort: sorts)
      dismiss()
    } catch { self.error = error.localizedDescription }
  }
}
