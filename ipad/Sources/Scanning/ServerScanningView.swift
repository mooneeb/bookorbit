import SwiftUI

struct ServerScanningView: View {
  let api: BookOrbitAPI
  let user: AuthUser
  let openDock: () -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var libraries: [Library] = []
  @State private var dockSettings: BookDockSettings?
  @State private var message: String?
  @State private var isBusy = false

  var body: some View {
    NavigationStack {
      List {
        if let message {
          Section {
            Text(message).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier(
              "serverScanNotice")
          }
        }
        if user.hasPermission(.bookDockAccess) && user.hasPermission(.manageBookDock) {
          Section("Book Dock staging") {
            Text(
              "Scan the server Book Dock folder, then review metadata and destination before finalizing."
            )
            if let dockSettings {
              LabeledContent("Server folder", value: dockSettings.bookDockPath)
                .accessibilityIdentifier("bookDockServerFolder")
            }
            Button("Scan Book Dock folder", action: rescanDock).disabled(isBusy)
              .accessibilityIdentifier("scanBookDockFolder")
            Button("Review Book Dock", action: openDock).accessibilityIdentifier(
              "scanReviewBookDock")
          }
        }
        if user.hasPermission(.manageLibraries) {
          Section("Configured libraries") {
            Text(
              "Library scans adopt files in their current server folders. Book Dock provides metadata review before import."
            )
            ForEach(libraries) { library in
              NavigationLink {
                LibraryScanView(api: api, user: user, library: library)
              } label: {
                Text(library.name)
              }
              .accessibilityIdentifier("scanLibrary_\(library.id)")
            }
            if libraries.isEmpty { Text("No accessible book libraries.") }
          }
        }
      }
      .navigationTitle("Server scans")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done", action: dismiss.callAsFunction).accessibilityIdentifier(
            "closeServerScanning")
        }
        ToolbarItem(placement: .primaryAction) {
          Button("Reload", action: reload).disabled(isBusy).accessibilityIdentifier(
            "reloadServerScanning")
        }
      }
      .task { await load() }
    }
  }

  private func reload() { Task { await load() } }
  private func load() async {
    isBusy = true
    defer { isBusy = false }
    do {
      if user.hasPermission(.manageLibraries) {
        let result: [Library] = try await api.boundedJSON(
          "libraries", byteLimit: 512 * 1024, expectedStatus: 200)
        libraries = result.filter { $0.type == "books" }
      }
      if user.hasPermission(.bookDockAccess) && user.hasPermission(.manageBookDock) {
        dockSettings = try await api.dockScanSettings()
      }
      message = nil
    } catch { message = error.localizedDescription }
  }
  private func rescanDock() {
    Task {
      isBusy = true
      defer { isBusy = false }
      do {
        try await api.rescanDock()
        message =
          "Server folder scanned. Review Book Dock while metadata processing finishes. Repeating discovery keeps existing staged files."
      } catch {
        message =
          "The response was not confirmed. Review Book Dock before scanning again. \(error.localizedDescription)"
      }
    }
  }
}
