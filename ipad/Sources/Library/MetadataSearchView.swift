import SwiftUI

struct MetadataSearchView: View {
  @State private var model: MetadataSearchModel
  @Bindable var draft: MetadataDraft
  let applied: () -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var selected: MetadataMatch?

  init(api: BookOrbitAPI, book: BookDetail, draft: MetadataDraft, applied: @escaping () -> Void) {
    _model = State(initialValue: MetadataSearchModel(api: api, book: book))
    self.draft = draft
    self.applied = applied
  }

  var body: some View {
    VStack(spacing: 0) {
      Text("Find metadata").font(.title2).padding().accessibilityAddTraits(.isHeader)
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 20) {
          input("Title", text: $model.title, identifier: "metadataSearchTitle")
          input("Author", text: $model.author, identifier: "metadataSearchAuthor")
          input("ISBN", text: $model.isbn, identifier: "metadataSearchISBN")
          Picker("Search medium", selection: $model.medium) {
            Text("Ebook").tag("ebook")
            Text("Audiobook").tag("audiobook")
            Text("Comic").tag("comic")
          }.frame(minHeight: 44).disabled(model.isSearching)
          if model.isLoadingProviders { ProgressView("Loading providers…") }
          ForEach(model.providers, id: \.key) { provider in
            Toggle(
              provider.label,
              isOn: Binding(
                get: { model.selectedProviders.contains(provider.key) },
                set: {
                  if $0 {
                    model.selectedProviders.insert(provider.key)
                  } else {
                    model.selectedProviders.remove(provider.key)
                  }
                })
            )
            .disabled(model.isSearching)
            .accessibilityIdentifier("metadataSearchProvider\(provider.key)")
          }
          if model.providers.isEmpty && !model.isLoadingProviders {
            Text("No active providers are available.").fixedSize(horizontal: false, vertical: true)
            Button("Reload providers") { Task { await model.loadProviders() } }.frame(minHeight: 44)
          }
          Button("Search metadata") { model.search() }.frame(minHeight: 44)
            .disabled(model.isSearching || model.isLoadingProviders)
            .accessibilityIdentifier("metadataSearch")
          if !model.providers.filter(\.identifiable).isEmpty {
            Text("Identify a provider record").font(.headline)
            Picker("Provider", selection: $model.lookupProvider) {
              ForEach(model.providers.filter(\.identifiable), id: \.key) {
                Text($0.label).tag($0.key)
              }
            }.frame(minHeight: 44).disabled(model.isSearching)
            input("Provider identifier", text: $model.providerID, identifier: "metadataLookupID")
            Button("Identify", action: model.identify).frame(minHeight: 44)
              .disabled(model.isSearching).accessibilityIdentifier("metadataIdentify")
          }
          if let error = model.error {
            Label(error, systemImage: "exclamationmark.triangle").fixedSize(
              horizontal: false, vertical: true
            )
            .accessibilityIdentifier("metadataSearchError")
          }
          ForEach(model.statuses.keys.sorted(), id: \.self) { provider in
            VStack(alignment: .leading) {
              Text("\(provider): \(model.statuses[provider] ?? "failed")")
              Button("Retry \(provider)") { model.search(only: provider) }.frame(minHeight: 44)
                .disabled(model.isSearching)
            }
          }
          if model.isSearching { ProgressView("Searching metadata…") }
          if model.hasSearched, model.matches.isEmpty, !model.isSearching, model.error == nil {
            Text("No matching metadata found.").fixedSize(horizontal: false, vertical: true)
          }
          ForEach(model.matches) { match in
            Button {
              model.cancel()
              selected = match
            } label: {
              VStack(alignment: .leading, spacing: 8) {
                Text(
                  match.candidate.displayTitle ?? match.candidate.title
                    ?? "Untitled provider record"
                )
                .font(.headline).fixedSize(horizontal: false, vertical: true)
                Text(match.candidate.authors?.joined(separator: ", ") ?? "")
                Text(match.candidate.provider)
              }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .accessibilityIdentifier("metadataMatch\(match.id)")
          }
        }.padding()
      }
      .scrollEdgeEffectHidden().clipped()
      HStack {
        Button("Done", action: dismiss.callAsFunction).frame(minWidth: 44, minHeight: 44)
        Spacer()
        if model.isSearching {
          Button("Cancel search", action: model.cancel).frame(minWidth: 44, minHeight: 44)
        }
      }
      .font(.body).buttonStyle(.plain).padding(.horizontal)
      .background(Color(uiColor: .systemBackground))
    }
    .foregroundStyle(Color(uiColor: .label)).background(Color(uiColor: .systemBackground))
    .task { await model.loadProviders() }
    .onDisappear(perform: model.cancel)
    .fullScreenCover(item: $selected) { match in
      MetadataComparisonView(api: model.api, match: match, draft: draft, applied: applied)
    }
  }

  private func input(_ label: String, text: Binding<String>, identifier: String) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(label).font(.headline)
      TextField("", text: text).textFieldStyle(.roundedBorder)
        .textInputAutocapitalization(.never).autocorrectionDisabled()
        .frame(minHeight: 44).accessibilityLabel(label).accessibilityIdentifier(identifier)
        .disabled(model.isSearching)
    }
  }
}
