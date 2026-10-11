import SwiftUI

struct ContentRestrictionUsersView: View {
  let api: BookOrbitAPI
  @State private var model: ContentRestrictionUsersModel

  init(api: BookOrbitAPI) {
    self.api = api
    _model = State(initialValue: ContentRestrictionUsersModel(api: api))
  }

  var body: some View {
    List {
      Section {
        TextField("Search readers", text: $model.search)
          .textInputAutocapitalization(.never)
          .onSubmit { Task { await model.load() } }
          .accessibilityIdentifier("contentRestrictionUserSearch")
        Button("Search readers") { Task { await model.load() } }
          .accessibilityIdentifier("contentRestrictionSearchUsers")
          .disabled(model.isBusy)
      }
      if let users = model.users {
        Section("Readers") {
          ForEach(users.users) { target in
            if target.isSuperuser {
              LabeledContent(target.username, value: "Administrator: unrestricted")
                .foregroundStyle(.secondary)
            } else {
              NavigationLink {
                ContentRestrictionEditorView(api: api, target: target)
              } label: {
                VStack(alignment: .leading) {
                  Text(target.name)
                  Text(target.username).font(.footnote).foregroundStyle(.secondary)
                }
              }
              .accessibilityIdentifier("contentRestrictionUser\(target.id)")
            }
          }
          if users.users.isEmpty { Text("No readers match your search.") }
        }
        Section {
          HStack {
            Button("Previous readers") { Task { await model.load(page: model.page - 1) } }
              .disabled(model.isBusy || model.page == 0)
            Spacer()
            Button("Next readers") { Task { await model.load(page: model.page + 1) } }
              .disabled(model.isBusy || (model.page + 1) * 20 >= users.total)
          }
        }
      }
      if model.isBusy { ProgressView("Loading readers") }
      if let error = model.error {
        Text(error).foregroundStyle(.red)
        Button("Retry") { Task { await model.load(page: model.page) } }
      }
    }
    .navigationTitle("Content restrictions")
    .task { await model.load() }
  }
}

private enum ContentRestrictionRule: String, Identifiable {
  case includeTags, excludeTags, includeGenres, excludeGenres
  var id: String { rawValue }
  var title: String {
    switch self {
    case .includeTags: "Included tags"
    case .excludeTags: "Excluded tags"
    case .includeGenres: "Included genres"
    case .excludeGenres: "Excluded genres"
    }
  }
  var kind: String {
    switch self {
    case .includeTags, .excludeTags: "tags"
    case .includeGenres, .excludeGenres: "genres"
    }
  }
}

struct ContentRestrictionEditorView: View {
  let api: BookOrbitAPI
  @State private var model: ContentRestrictionEditorModel
  @State private var editingRule: ContentRestrictionRule?

  init(api: BookOrbitAPI, target: UserRestrictionTarget) {
    self.api = api
    _model = State(initialValue: ContentRestrictionEditorModel(api: api, target: target))
  }

  var body: some View {
    Form {
      Section {
        Text(
          "Include rules permit a matching tag or genre. Exclude rules then hide matches. Empty include rules allow all otherwise permitted books."
        )
        .font(.footnote).foregroundStyle(.secondary)
      }
      ForEach([ContentRestrictionRule.includeTags, .excludeTags, .includeGenres, .excludeGenres]) {
        rule in
        Section(rule.title) {
          let binding = selection(rule)
          ForEach(binding.wrappedValue) { item in
            HStack {
              Text(item.name)
              Spacer()
              Button("Remove \(item.name)", systemImage: "minus.circle") {
                binding.wrappedValue.removeAll { $0.id == item.id }
              }
              .labelStyle(.iconOnly)
              .accessibilityIdentifier("contentRestrictionRemove\(rule.rawValue)\(item.id)")
            }
          }
          Button("Add \(rule.kind)") { editingRule = rule }
            .accessibilityIdentifier("contentRestrictionAdd\(rule.rawValue)")
        }
        .disabled(model.isBusy || !model.isLoaded)
      }
      Section {
        Toggle("Allow own fulfilled requests", isOn: $model.filters.seeOwnRequestedBooks)
          .accessibilityIdentifier("contentRestrictionOwnRequests")
          .disabled(model.isBusy || !model.isLoaded)
        saveFeedback
      }
    }
    .accessibilityIdentifier("contentRestrictionContent")
    .navigationTitle(model.target.username)
    .disabled(model.target.isSuperuser)
    .task { await model.load() }
    .sheet(item: $editingRule) { rule in
      ContentRestrictionChoiceView(api: api, kind: rule.kind, selected: selection(rule))
    }
  }

  private var saveFeedback: some View {
    VStack(alignment: .leading, spacing: 12) {
      if model.isBusy { ProgressView("Updating content restrictions") }
      if let message = model.message {
        Text(message).accessibilityIdentifier("contentRestrictionSaved")
      }
      if let error = model.error {
        Text(error).foregroundStyle(.red).accessibilityIdentifier("contentRestrictionError")
        Button("Reload restrictions") { Task { await model.load() } }
          .disabled(model.isBusy)
      }
      Button("Save content restrictions") { Task { await model.save() } }
        .accessibilityIdentifier("contentRestrictionSave")
        .disabled(model.isBusy || !model.isLoaded)
    }
  }

  private func selection(_ rule: ContentRestrictionRule) -> Binding<[ContentFilterNamedItem]> {
    switch rule {
    case .includeTags: $model.filters.includeTags
    case .excludeTags: $model.filters.excludeTags
    case .includeGenres: $model.filters.includeGenres
    case .excludeGenres: $model.filters.excludeGenres
    }
  }
}

private struct ContentRestrictionChoiceView: View {
  let api: BookOrbitAPI
  let kind: String
  @Binding var selected: [ContentFilterNamedItem]
  @Environment(\.dismiss) private var dismiss
  @State private var search = ""
  @State private var results: [CatalogSearchResult] = []
  @State private var isBusy = false
  @State private var error: String?

  var body: some View {
    NavigationStack {
      List {
        TextField("Search \(kind)", text: $search)
          .onSubmit { Task { await findChoices() } }
          .accessibilityIdentifier("contentRestrictionChoiceSearch")
        Button("Search \(kind)") { Task { await findChoices() } }
          .disabled(isBusy)
          .accessibilityIdentifier("contentRestrictionChoiceFind")
        ForEach(results, id: \.name) { result in
          if let id = result.id {
            Button {
              if !selected.contains(where: { $0.id == id }) {
                selected.append(ContentFilterNamedItem(id: id, name: result.name))
              }
              dismiss()
            } label: {
              HStack {
                Text(result.name)
                Spacer()
                if selected.contains(where: { $0.id == id }) { Image(systemName: "checkmark") }
              }
            }
            .accessibilityIdentifier("contentRestrictionChoice\(id)")
          }
        }
        if isBusy { ProgressView("Searching \(kind)") }
        if let error { Text(error).foregroundStyle(.red) }
      }
      .navigationTitle("Add \(kind)")
      .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
    }
  }

  private func findChoices() async {
    guard !isBusy else { return }
    isBusy = true
    error = nil
    results = []
    defer { isBusy = false }
    do {
      let session = try await api.authenticatedSessionGeneration()
      let results = try await api.readingRestrictionChoices(
        kind: kind, search: search, session: session)
      try Task.checkCancellation()
      self.results = results
    } catch {
      if !Task.isCancelled { self.error = error.localizedDescription }
    }
  }
}
