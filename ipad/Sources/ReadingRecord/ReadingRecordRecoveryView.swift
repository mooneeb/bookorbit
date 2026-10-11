import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct NativeReadingRecoveryItem: Identifiable {
  let id: String
  let title: String
  let reason: String
}

struct ReadingRecordRecoveryDocument: FileDocument {
  static var readableContentTypes: [UTType] { [.json] }
  var data: Data

  init(data: Data) { self.data = data }
  init(configuration: ReadConfiguration) throws {
    guard let data = configuration.file.regularFileContents else {
      throw ConnectionError.invalidResponse
    }
    self.data = data
  }
  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: data)
  }
}

struct ReadingRecordRecoveryView: View {
  let api: BookOrbitAPI
  @State private var items: [NativeReadingRecoveryItem] = []
  @State private var document: ReadingRecordRecoveryDocument?
  @State private var showsExport = false
  @State private var isLoading = false
  @State private var error: String?
  @State private var message: String?
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        Section {
          Text(
            "Local recovery versions are kept when a book, reading attempt, or field changed. Export preserves your original work without restoring deleted server data."
          )
          if let error { Text(error).accessibilityIdentifier("readingRecoveryError") }
          if let message { Text(message).accessibilityIdentifier("readingRecoveryExportState") }
          Button("Export local reading recovery") { Task { await export() } }
            .disabled(isLoading || items.isEmpty).accessibilityIdentifier("readingRecoveryExport")
        }
        Section("Recovery versions") {
          if isLoading {
            ProgressView("Loading recovery versions…")
          } else if items.isEmpty {
            Text("No reading records need recovery.")
          }
          ForEach(items) { item in
            VStack(alignment: .leading, spacing: 8) {
              Text(item.title).font(.headline)
              Text(item.reason)
            }.accessibilityIdentifier("readingRecoveryItem\(item.id)")
          }
        }
      }.navigationTitle("Reading record recovery")
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Done", action: dismiss.callAsFunction)
          }
        }
        .task { await load() }
        .fileExporter(
          isPresented: $showsExport, document: document, contentType: .json,
          defaultFilename: "BookOrbit reading recovery"
        ) { result in
          switch result {
          case .success:
            message = "Reading recovery exported. The local versions stay on this iPad."
          case .failure(let failure): error = failure.localizedDescription
          }
        }
    }
  }

  private func load() async {
    isLoading = true
    defer { isLoading = false }
    do {
      let activity = try await NativeReadingActivityCoordinator.open(api: api)
      let personal = try await NativePersonalReadingOutbox.open(api: api)
      let attempts = try await NativeReadingAttemptOutbox.open(api: api)
      items = activity.recoveryItems + personal.recoveryItems + attempts.recoveryItems
    } catch { self.error = error.localizedDescription }
  }

  private func export() async {
    do {
      let namespace = try await api.storageNamespace()
      let activity = try await NativeReadingActivityCoordinator.open(api: api)
      let personal = try await NativePersonalReadingOutbox.open(api: api)
      let attempts = try await NativeReadingAttemptOutbox.open(api: api)
      let object: [String: Any] = [
        "version": 1,
        "readingSessions": try JSONSerialization.jsonObject(with: activity.recoveryData()),
        "personalRecords": try JSONSerialization.jsonObject(with: personal.recoveryData()),
        "readingHistory": try JSONSerialization.jsonObject(with: attempts.recoveryData()),
      ]
      let data = try JSONSerialization.data(
        withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
      guard try await api.storageNamespace() == namespace else {
        throw ConnectionError.expiredSession
      }
      document = ReadingRecordRecoveryDocument(data: data)
      showsExport = true
    } catch { self.error = error.localizedDescription }
  }
}
