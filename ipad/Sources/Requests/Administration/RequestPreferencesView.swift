import SwiftUI

struct RequestPreferencesView: View {
  let api: BookOrbitAPI
  @State private var language = ""
  @State private var busy = false
  @State private var loaded = false
  @State private var error: String?
  @State private var saved = false

  var body: some View {
    Form {
      Section("New requests") {
        Picker("Default language", selection: $language) {
          Text("Use edition language").tag("")
          ForEach(BookRequestLanguageVocabulary.codes, id: \.self) { code in
            Text(Locale.current.localizedString(forLanguageCode: code) ?? code).tag(code)
          }
        }.pickerStyle(.menu).accessibilityIdentifier("requestDefaultLanguage")
      }
      if let error {
        Text(error)
        Button("Retry", action: reload)
      }
      if saved { Text("Request preferences saved.") }
      Button("Save preferences", action: save).disabled(busy || !loaded)
    }
    .navigationTitle("Request preferences")
    .disabled(busy)
    .task { await load() }
  }
  private func reload() { Task { await load() } }
  private func load() async {
    guard !busy else { return }
    busy = true
    error = nil
    defer { busy = false }
    do {
      let value: RequestPreferenceEnvelope = try await api.boundedJSON(
        "user-preferences/book-requests")
      language = value.settings.defaultLanguage ?? ""
      loaded = true
    } catch { self.error = error.localizedDescription }
  }
  private func save() {
    Task {
      guard !busy else { return }
      busy = true
      error = nil
      saved = false
      defer { busy = false }
      do {
        try await api.sendEmpty(
          "user-preferences/book-requests", method: "PUT",
          body: JSONSerialization.data(withJSONObject: [
            "settings": ["defaultLanguage": language.isEmpty ? NSNull() : language as Any]
          ]), expectedStatus: 204)
        saved = true
      } catch { self.error = error.localizedDescription }
    }
  }
}

private struct RequestPreferenceEnvelope: Decodable, Sendable {
  let settings: BookRequestPreferences
}
