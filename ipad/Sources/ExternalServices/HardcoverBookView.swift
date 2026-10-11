import SwiftUI

struct HardcoverBookView: View {
  let title: String
  @State private var model: HardcoverBookModel
  @Environment(\.scenePhase) private var scenePhase

  init(api: BookOrbitAPI, bookID: Int, title: String) {
    self.title = title
    _model = State(initialValue: HardcoverBookModel(api: api, bookID: bookID))
  }

  var body: some View {
    Form {
      Section(title) {
        if let state = model.state {
          Text(state.syncEnabled ? "Included in Hardcover sync" : "Excluded from Hardcover sync")
            .accessibilityIdentifier("hardcoverBookSelection")
          if let reason = state.effectiveReason {
            Text(reason.replacingOccurrences(of: "_", with: " ").capitalized)
              .accessibilityIdentifier("hardcoverBookEligibility")
          }
          if let checked = state.lastSyncedAt {
            Text("\(model.lastActivityTitle): \(checked)")
              .accessibilityIdentifier("hardcoverBookLastSynced")
          }
          if let feedback = model.syncFeedback {
            Text(feedback).accessibilityIdentifier("hardcoverBookSyncError")
          }
          Button(state.syncEnabled ? "Exclude this book" : "Include this book") {
            Task { await model.changeInclusion() }
          }.accessibilityIdentifier("hardcoverBookInclude")
          Button(state.syncError == nil ? "Sync reading record" : "Retry reading record") {
            Task { await model.sync() }
          }.disabled(!state.syncEnabled).accessibilityIdentifier("hardcoverBookSync")
        }
        Button("Refresh sync state") { Task { await model.load() } }
          .accessibilityIdentifier("hardcoverBookRefresh")
        Text(
          "Only your reading status, rating, dates and progress are sent. Personal notes and highlights remain in BookOrbit."
        )
        .fixedSize(horizontal: false, vertical: true)
      }
      Section("Hardcover edition") {
        Button("Find editions") { Task { await model.loadEditions() } }
          .accessibilityIdentifier("hardcoverBookEditions")
        if let editions = model.editions {
          ForEach(editions.editions, id: \.id) { edition in
            Button {
              Task { await model.selectEdition(edition.id) }
            } label: {
              VStack(alignment: .leading) {
                Text(edition.title ?? "Edition \(edition.id)")
                Text(
                  "\(edition.format), \(edition.pages.map { "\($0) pages" } ?? "page count unavailable")"
                )
                .font(.caption)
                if let publisher = edition.publisher { Text(publisher).font(.caption) }
              }
            }.accessibilityIdentifier("hardcoverEdition\(edition.id)")
          }
          if editions.truncated {
            Text(
              "More editions are available. Enter an edition ID below to select another edition of this matched book."
            )
          }
        }
        TextField("Edition ID", text: $model.editionID).keyboardType(.numberPad)
          .accessibilityIdentifier("hardcoverEditionID")
        Button("Select edition ID") {
          if let id = Int(model.editionID) { Task { await model.selectEdition(id) } }
        }.disabled(Int(model.editionID).map { $0 > 0 } != true)
          .accessibilityIdentifier("hardcoverSelectEdition")
      }
      if let message = model.message {
        Section { Text(message).accessibilityIdentifier("hardcoverBookMessage") }
      }
      if let error = model.error {
        Section { Text(error).accessibilityIdentifier("hardcoverBookError") }
      }
    }.disabled(model.busy).navigationTitle("Hardcover book")
      .overlay { if model.busy { ProgressView("Contacting Hardcover") } }
      .task { await model.load() }
      .onChange(of: scenePhase) { _, phase in
        if phase == .active { Task { await model.load() } }
      }
  }
}
