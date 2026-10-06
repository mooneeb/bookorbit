import SwiftUI

struct CoverSearchView: View {
  @State private var model: CoverSearchModel
  let medium: CoverMedium
  let selected: (String) -> Void
  @Environment(\.dismiss) private var dismiss

  init(
    api: BookOrbitAPI, book: BookDetail, medium: CoverMedium, selected: @escaping (String) -> Void
  ) {
    self.medium = medium
    self.selected = selected
    _model = State(initialValue: CoverSearchModel(api: api, book: book, medium: medium))
  }

  var body: some View {
    VStack(spacing: 0) {
      Text("Find \(medium.rawValue) cover").font(.title2).padding().accessibilityAddTraits(
        .isHeader)
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 16) {
          Text("Title").font(.headline)
          TextField("", text: $model.title).textFieldStyle(.roundedBorder).frame(minHeight: 44)
            .accessibilityLabel("Title").accessibilityIdentifier("coverSearchTitle")
          Text("Author").font(.headline)
          TextField("", text: $model.author).textFieldStyle(.roundedBorder).frame(minHeight: 44)
            .accessibilityLabel("Author").accessibilityIdentifier("coverSearchAuthor")
          Picker("Cover provider", selection: $model.provider) {
            ForEach(MetadataVocabulary.coverProviders, id: \.self) { Text($0).tag($0) }
          }.frame(minHeight: 44)
          Toggle("Search audiobook covers", isOn: $model.isAudiobook)
          Button("Find covers", action: model.search).frame(minHeight: 44)
            .disabled(model.isSearching).accessibilityIdentifier("coverSearch")
          Text("Choosing an image stages it. Save the cover to keep the change.")
            .fixedSize(horizontal: false, vertical: true)
          if model.isSearching { ProgressView("Searching covers…") }
          if let error = model.error {
            Label(error, systemImage: "exclamationmark.triangle").fixedSize(
              horizontal: false, vertical: true
            )
            .accessibilityIdentifier("coverSearchError")
          }
          if model.hasSearched, !model.isSearching, model.results.isEmpty, model.error == nil {
            Text("No covers found.").fixedSize(horizontal: false, vertical: true)
          }
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 240))], spacing: 24) {
            ForEach(model.results) { match in
              VStack(alignment: .leading, spacing: 12) {
                RemoteCoverPreview(
                  api: model.api, url: match.url,
                  label:
                    "\(match.result.source) cover, \(match.result.width) by \(match.result.height)")
                Text(match.result.source)
                Text("\(match.result.width) × \(match.result.height)")
                Button("Choose \(medium.rawValue) cover") {
                  selected(match.url)
                  dismiss()
                }
                .frame(minHeight: 44).disabled(!match.isDownloadable)
                .accessibilityLabel(
                  "Choose \(medium.rawValue) cover from \(match.result.source), \(match.result.width) by \(match.result.height)"
                )
                .accessibilityIdentifier("coverSearchChoose\(match.id)")
              }
            }
          }
        }
        .textInputAutocapitalization(.never).autocorrectionDisabled().padding()
      }
      .scrollEdgeEffectHidden().clipped()
      HStack {
        Button("Done", action: dismiss.callAsFunction).frame(minWidth: 44, minHeight: 44)
        Spacer()
        if model.isSearching {
          Button("Cancel search", action: model.cancel).frame(minWidth: 44, minHeight: 44)
        }
      }
      .font(.body).buttonStyle(.plain).padding(.horizontal).background(
        Color(uiColor: .systemBackground))
    }
    .foregroundStyle(Color(uiColor: .label)).background(Color(uiColor: .systemBackground))
    .onDisappear(perform: model.cancel)
  }
}
