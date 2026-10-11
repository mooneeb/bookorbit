import SwiftUI

@MainActor @Observable
final class NativePrivacyModel {
  let api: BookOrbitAPI
  var level = "private"
  var loaded = false
  var history: ReadingInsightsAccessHistoryPage?
  var page = 1
  var isBusy = false
  var error: String?
  var savedMessage: String?
  init(api: BookOrbitAPI) { self.api = api }

  func load() async {
    await perform {
      let settings = try await self.api.personalPrivacy()
      self.level = settings.sharingLevel
      self.history = try await self.api.personalPrivacyHistory(page: self.page)
      self.loaded = true
    }
  }

  func save() async {
    await perform {
      let settings = try await self.api.savePersonalPrivacy(self.level)
      self.level = settings.sharingLevel
      self.savedMessage = "Privacy saved to your account."
    }
  }

  func historyPage(_ page: Int) async {
    await perform {
      let history = try await self.api.personalPrivacyHistory(page: page)
      self.history = history
      self.page = page
    }
  }

  private func perform(_ action: () async throws -> Void) async {
    guard !isBusy else { return }
    isBusy = true
    error = nil
    defer { isBusy = false }
    do { try await action() } catch { self.error = error.localizedDescription }
  }
}

struct NativePrivacyView: View {
  @State private var model: NativePrivacyModel
  @State private var confirming = false
  init(api: BookOrbitAPI) { _model = State(initialValue: NativePrivacyModel(api: api)) }
  var body: some View {
    Form {
      Section {
        Picker("Reading insights sharing", selection: $model.level) {
          Text("Private").tag("private")
          Text("Summary").tag("summary")
          Text("Detailed").tag("detailed")
        }.accessibilityIdentifier("privacySharingLevel")
        Text(
          "Summary shares totals and trends. Detailed also shares your book-level reading history with authorized viewers."
        )
        Button("Save privacy") { confirming = true }.disabled(!model.loaded || model.isBusy)
          .accessibilityIdentifier("savePrivacy")
      } footer: {
        Text("Privacy is enforced by the server and shared across your account.")
      }
      Section("Who viewed your insights") {
        if let history = model.history {
          if history.items.isEmpty { Text("No recorded views") }
          ForEach(history.items, id: \.id) { item in
            VStack(alignment: .leading) {
              Text(item.viewerUsername).font(.headline)
              Text("\(item.sharingLevel.capitalized): \(item.viewedAt)").font(.caption)
            }
          }
          HStack {
            Button("Previous") { Task { await model.historyPage(model.page - 1) } }.disabled(
              model.page <= 1 || model.isBusy)
            Spacer()
            Text("Page \(model.page)")
            Spacer()
            Button("Next") { Task { await model.historyPage(model.page + 1) } }
              .disabled(model.page * 20 >= history.total || model.isBusy)
          }
        }
      }
      if let message = model.savedMessage { Text(message).accessibilityIdentifier("privacySaved") }
      if let error = model.error {
        Section {
          Text(error).foregroundStyle(.red)
          Button("Try again") { Task { await model.load() } }
        }
      }
      if model.isBusy { ProgressView("Loading privacy") }
    }.navigationTitle("Privacy and sharing").task { await model.load() }
      .confirmationDialog("Change reading insights sharing?", isPresented: $confirming) {
        Button("Save privacy") { Task { await model.save() } }
      } message: {
        Text("Your selected level will apply to future access from every device.")
      }
  }
}
