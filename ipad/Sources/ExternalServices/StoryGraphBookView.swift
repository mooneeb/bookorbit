import SwiftUI

struct StoryGraphBookView: View {
  @State private var model: StoryGraphBookModel

  init(api: BookOrbitAPI, bookID: Int, title: String) {
    _model = State(initialValue: StoryGraphBookModel(api: api, bookID: bookID, title: title))
  }

  var body: some View {
    Form {
      Section(model.title) {
        Toggle("Include this book in StoryGraph sync", isOn: $model.selected)
          .accessibilityIdentifier("storygraphBookSelected")
        Button("Save book selection", action: saveSelection).disabled(
          model.isBusy || model.state == nil)
        if let state = model.state {
          LabeledContent("Eligibility", value: reason(state.effectiveReason))
          LabeledContent("Last accepted", value: state.lastSyncedAt ?? "Never")
          if let error = state.syncError {
            Text(error).accessibilityIdentifier("storygraphBookSyncError")
          }
          Button("Sync this book", action: sync)
            .disabled(model.isBusy || !state.canSyncNow).accessibilityIdentifier(
              "storygraphBookSync")
        }
      }
      Section("StoryGraph match") {
        TextField("StoryGraph book URL or ID", text: $model.input)
          .autocorrectionDisabled().textInputAutocapitalization(.never)
          .accessibilityIdentifier("storygraphBookLinkInput")
        Button("Link StoryGraph book", action: link).disabled(!model.canLink)
          .accessibilityIdentifier("storygraphBookLink")
        Button("Find a new match and sync", action: rematch).disabled(
          model.isBusy || model.state?.syncEnabled != true)
        Button("Load available editions", action: loadEditions).disabled(model.isBusy)
          .accessibilityIdentifier("storygraphEditions")
        ForEach(model.editions, id: \.id) { edition in
          Button {
            choose(edition)
          } label: {
            VStack(alignment: .leading) {
              Text(edition.title)
              Text(
                [edition.format, edition.language, edition.isbn].compactMap { $0 }.joined(
                  separator: ", ")
              )
              .font(.footnote).foregroundStyle(.secondary)
            }
          }.disabled(model.isBusy).accessibilityIdentifier("storygraphEdition\(edition.id)")
        }
      }
      if let error = model.error {
        Section("Action needs attention") {
          Text(error).accessibilityIdentifier("storygraphBookError")
        }
      }
      if let message = model.message {
        Section("Result") { Text(message).accessibilityIdentifier("storygraphBookResult") }
      }
      Section {
        Text(
          "Status and supported progress export only. Unread books are not exported. Excluding a book does not remove records already sent to StoryGraph."
        )
        .font(.footnote).foregroundStyle(.secondary)
        Button("Refresh book result", action: refresh).disabled(model.isBusy)
      }
    }
    .navigationTitle("StoryGraph book")
    .task { await model.load() }
  }

  private func reason(_ value: String?) -> String {
    switch value {
    case nil: "Eligible"
    case "missing_cookies": "Save StoryGraph credentials first"
    case "permission_denied": "StoryGraph permission required"
    case "user_disabled", "global_disabled": "Enable StoryGraph sync first"
    case "not_selected": "Select this book to export it"
    case "excluded": "Excluded from export"
    case "unread": "Unread books are not exported"
    default: "This reading status is unsupported"
    }
  }

  private func refresh() { Task { await model.load() } }
  private func saveSelection() { Task { await model.saveSelection() } }
  private func sync() { Task { await model.sync() } }
  private func rematch() { Task { await model.rematch() } }
  private func link() { Task { await model.link() } }
  private func loadEditions() { Task { await model.loadEditions() } }
  private func choose(_ edition: StorygraphEdition) { Task { await model.chooseEdition(edition) } }
}
