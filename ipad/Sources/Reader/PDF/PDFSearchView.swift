import PDFKit
import SwiftUI

struct PDFSearchView: View {
  @State private var model: PDFSearchModel
  @State private var query = ""
  @FocusState private var isQueryFocused: Bool
  @Environment(\.dismiss) private var dismiss
  let onSelect: (PDFSearchMatch) -> Void

  init(document: PDFDocument, onSelect: @escaping (PDFSearchMatch) -> Void) {
    _model = State(initialValue: PDFSearchModel(document: document))
    self.onSelect = onSelect
  }

  private var phrase: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
  private var isTooLong: Bool { phrase.unicodeScalars.prefix(201).count > 200 }

  var body: some View {
    NavigationStack {
      List {
        Section {
          LabeledContent("Find") {
            TextField("Word or phrase", text: $query)
              .accessibilityLabel("Search text")
              .accessibilityIdentifier("pdfSearchQuery")
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
              .submitLabel(.search)
              .focused($isQueryFocused)
              .onSubmit(find)
          }
          Button("Clear search", action: clearQuery)
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .frame(minHeight: 44)
            .accessibilityIdentifier("pdfClearSearch")
            .disabled(query.isEmpty)
          if isTooLong { Text("Use a shorter search phrase.") }
        }
        if let error = model.error { Section { Text(error) } }
        if model.hasSearched {
          Section {
            if model.isSearching { ProgressView("Searching PDF…") }
            if !model.isSearching && model.matches.isEmpty {
              ContentUnavailableView {
                Label("No matches", systemImage: "magnifyingglass")
              } description: {
                Text("Try a different word or phrase.").foregroundStyle(.primary)
              }
            }
            ForEach(model.matches) { match in
              Button {
                onSelect(match)
                dismiss()
              } label: {
                VStack(alignment: .leading) {
                  Text("Page \(match.pageIndex + 1)").font(.headline)
                  Text(match.text).font(.body)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              .foregroundStyle(.primary)
              .accessibilityElement(children: .combine)
              .accessibilityIdentifier("pdfSearchResult\(match.id)")
            }
            if model.reachedLimit {
              Text("Showing the first 100 matches. Refine your search.")
            }
          }
        }
      }
      .navigationTitle("Search PDF")
      .navigationBarTitleDisplayMode(.inline)
      .safeAreaInset(edge: .bottom) {
        HStack {
          Button("Cancel", action: dismiss.callAsFunction).frame(minHeight: 44)
          Spacer()
          Button("Search", action: find)
            .frame(minHeight: 44)
            .accessibilityIdentifier("pdfFindText")
            .disabled(phrase.isEmpty || isTooLong || model.isSearching)
        }
        .font(.body)
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .padding(.horizontal)
        .background(.background)
      }
      .toolbar {
        ToolbarItemGroup(placement: .keyboard) {
          Spacer()
          Button("Hide keyboard") { isQueryFocused = false }
        }
      }
    }
    .onChange(of: query) { model.clear() }
    .onDisappear { model.stop() }
  }

  private func find() {
    isQueryFocused = false
    model.search(phrase)
  }

  private func clearQuery() {
    query = ""
    isQueryFocused = true
  }
}
