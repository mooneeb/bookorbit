import SwiftUI

struct KoboHistoryView: View {
  let api: BookOrbitAPI
  @State private var history: [KoboSyncHistoryEntry] = []
  @State private var isBusy = false
  @State private var error: String?

  var body: some View {
    List {
      Section {
        Text(
          "These are completed requests from your Kobo devices. After a failure, sync the device again to retry, then refresh this history."
        )
        Button("Refresh delivery history", action: reload).disabled(isBusy)
          .accessibilityIdentifier("koboRefreshHistory")
      }
      if isBusy { ProgressView("Loading sync history…") }
      if let error {
        Section("Could not load sync history") {
          Text(error).accessibilityIdentifier("koboHistoryError")
          Button("Try again", action: reload)
        }
      }
      if !isBusy, history.isEmpty, error == nil { Text("No Kobo requests have been recorded yet.") }
      ForEach(history, id: \.id) { entry in
        Section {
          Label(
            eventName(entry.event),
            systemImage: entry.status == "success" ? "checkmark.circle" : "exclamationmark.triangle"
          )
          .font(.headline)
          LabeledContent("Device", value: entry.deviceName ?? "Revoked device")
          LabeledContent("Outcome", value: entry.status == "success" ? "Completed" : "Failed")
          LabeledContent("Duration", value: "\(entry.durationMs) ms")
          ForEach(entry.counts.keys.sorted(), id: \.self) { key in
            if let wrapped = entry.counts[key], let value = wrapped {
              LabeledContent(key.replacingOccurrences(of: "_", with: " "), value: countLabel(value))
            }
          }
          Text(entry.createdAt).font(.caption).foregroundStyle(.secondary)
          if let error = entry.error {
            Text(error).accessibilityIdentifier("koboHistoryFailure\(entry.id)")
          }
        }.accessibilityIdentifier("koboHistoryEntry\(entry.id)")
      }
    }
    .accessibilityIdentifier("koboHistoryContent")
    .navigationTitle("Kobo sync history")
    .task { await load() }
  }

  private func eventName(_ event: String) -> String {
    switch event {
    case "library_sync": "Library sync"
    case "book_download": "Book download"
    case "progress_update": "Reading progress"
    case "annotations_pull": "Annotations sent to Kobo"
    case "annotations_push": "Annotations received from Kobo"
    default: event.replacingOccurrences(of: "_", with: " ").capitalized
    }
  }
  private func countLabel(_ value: KoboSyncHistoryEntryCountsValue) -> String {
    switch value {
    case .boolean(let value): value ? "Yes" : "No"
    case .number(let value): value.formatted()
    case .string(let value): value
    }
  }
  private func reload() { Task { await load() } }
  private func load() async {
    guard !isBusy else { return }
    isBusy = true
    error = nil
    defer { isBusy = false }
    do { history = try await api.koboHistory() } catch { self.error = error.localizedDescription }
  }
}
