import SwiftUI

struct MetadataDraftSuggestionButton: View {
  @Bindable var model: BookDetailModel
  @Bindable var draft: MetadataDraft
  @Binding var text: String
  let field: MetadataDraftSuggestionField
  let label: String
  let identifier: String
  var entryID: UUID? = nil
  @State private var presentation: MetadataDraftSuggestionScope?

  private var canChoose: Bool {
    guard !model.isSaving, model.book?.id == model.bookID, model.draft?.id == draft.id,
      !draft.lockedFields.contains(field.rawValue)
    else { return false }
    if field == .seriesName {
      guard !draft.lockedFields.contains("seriesIndex"), let entryID else { return false }
      return draft.extra.series.contains { $0.id == entryID }
    }
    return field != .narrators || draft.extra.hasAudio
  }

  var body: some View {
    Button("Choose existing \(label.lowercased())", systemImage: "text.magnifyingglass") {
      guard canChoose else { return }
      presentation = MetadataDraftSuggestionScope(
        bookID: model.bookID, draftID: draft.id, extraDraftID: ObjectIdentifier(draft.extra),
        field: field, entryID: entryID,
        initialQuery: field.isMultiple ? "" : text)
    }
    .frame(minHeight: 44)
    .disabled(!canChoose)
    .accessibilityIdentifier("\(identifier)Suggestions")
    .fullScreenCover(item: $presentation) { scope in
      MetadataDraftSuggestionsView(
        api: model.api, scope: scope, label: label, identifier: identifier,
        isCurrent: { isCurrent(scope) },
        choose: { name in
          guard isCurrent(scope) else { return }
          text = field.adding(name, to: text)
          presentation = nil
        },
        cancel: { presentation = nil })
    }
    .onChange(of: canChoose) { _, allowed in
      if !allowed { presentation = nil }
    }
    .onChange(of: ObjectIdentifier(draft.extra)) { _, _ in presentation = nil }
    .onChange(of: entryID) { _, _ in presentation = nil }
  }

  private func isCurrent(_ scope: MetadataDraftSuggestionScope) -> Bool {
    canChoose && presentation?.id == scope.id && model.bookID == scope.bookID
      && draft.id == scope.draftID && ObjectIdentifier(draft.extra) == scope.extraDraftID
      && field == scope.field && entryID == scope.entryID
  }
}

private struct MetadataDraftSuggestionsView: View {
  let scope: MetadataDraftSuggestionScope
  let label: String
  let identifier: String
  let choose: (String) -> Void
  let cancel: () -> Void
  @State private var query: String
  @State private var suggestions: MetadataDraftSuggestionsModel
  @State private var selectionTask: Task<Void, Never>?

  init(
    api: BookOrbitAPI, scope: MetadataDraftSuggestionScope, label: String, identifier: String,
    isCurrent: @escaping @MainActor () -> Bool, choose: @escaping (String) -> Void,
    cancel: @escaping () -> Void
  ) {
    self.scope = scope
    self.label = label
    self.identifier = identifier
    self.choose = choose
    self.cancel = cancel
    _query = State(initialValue: scope.initialQuery)
    _suggestions = State(
      initialValue: MetadataDraftSuggestionsModel(api: api, scope: scope, isCurrent: isCurrent))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text("Existing \(label.lowercased())").font(.headline)
          .accessibilityAddTraits(.isHeader)
        Spacer()
        Button("Cancel", action: cancelSelection)
          .frame(minWidth: 44, minHeight: 44)
          .accessibilityIdentifier("\(identifier)SuggestionsCancel")
      }
      .padding(.horizontal)
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          Text(
            scope.field.isMultiple
              ? "Selecting a name adds it to your draft."
              : "Selecting a value replaces this field in your draft.")
          Text("Changes stay in this draft until you save.").font(.footnote)
          HStack(alignment: .top) {
            TextField("Search existing values", text: $query, axis: .vertical)
              .textFieldStyle(.roundedBorder)
              .textInputAutocapitalization(.never).autocorrectionDisabled()
              .frame(minHeight: 44)
              .accessibilityLabel("Search existing \(label.lowercased())")
              .accessibilityIdentifier("\(identifier)SuggestionsSearch")
            Button("Clear search", systemImage: "xmark.circle", action: clearSearch)
              .labelStyle(.iconOnly)
              .frame(minWidth: 44, minHeight: 44)
              .disabled(query.isEmpty)
              .accessibilityIdentifier("\(identifier)SuggestionsClear")
          }
          .disabled(suggestions.isChoosing)
          if suggestions.isLoading {
            ProgressView("Finding existing values…")
              .accessibilityIdentifier("\(identifier)SuggestionsLoading")
          }
          if suggestions.isChoosing { ProgressView("Selecting value…") }
          if let error = suggestions.error {
            Text(error).fixedSize(horizontal: false, vertical: true)
              .accessibilityIdentifier("\(identifier)SuggestionsError")
            Button("Retry", action: retry)
              .frame(minHeight: 44)
              .accessibilityIdentifier("\(identifier)SuggestionsRetry")
          } else if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text("Enter a name to search existing values.")
          } else if suggestions.hasSearched, !suggestions.isLoading, suggestions.results.isEmpty {
            Text("No existing values match.")
              .accessibilityIdentifier("\(identifier)SuggestionsNoMatches")
          }
          LazyVStack(alignment: .leading, spacing: 8) {
            ForEach(suggestions.results, id: \.self) { name in
              Button {
                select(name)
              } label: {
                Text(name).fixedSize(horizontal: false, vertical: true)
                  .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                  .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              .disabled(suggestions.isChoosing)
              .accessibilityIdentifier("\(identifier)Suggestion_\(name)")
            }
          }
        }
        .padding()
      }
      .scrollEdgeEffectHidden()
    }
    .foregroundStyle(Color(uiColor: .label))
    .background(Color(uiColor: .systemBackground))
    .onChange(of: query, initial: true) { _, value in suggestions.search(query: value) }
    .onDisappear {
      selectionTask?.cancel()
      suggestions.close()
    }
  }

  private func select(_ name: String) {
    guard selectionTask == nil else { return }
    selectionTask = Task {
      if let value = await suggestions.selectedValue(name, query: query) { choose(value) }
      selectionTask = nil
    }
  }

  private func clearSearch() {
    query = ""
    suggestions.search(query: "")
  }

  private func retry() { suggestions.search(query: query, immediately: true) }

  private func cancelSelection() {
    selectionTask?.cancel()
    suggestions.close()
    cancel()
  }
}
