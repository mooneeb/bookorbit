import SwiftUI
import UniformTypeIdentifiers

struct AdministrationFontsView: View {
  let api: BookOrbitAPI
  let user: AuthUser
  @State private var fonts: [UserFont] = []
  @State private var message: String?
  @State private var busy = false
  @State private var importing = false

  private var canWrite: Bool {
    user.hasPermission(.manageAppSettings)
      && !user.permissions.contains(Permission.demoRestricted.rawValue)
  }
  var body: some View {
    List {
      AdministrationNotice(message: message)
      Section {
        Text(
          "Server fonts are available to every reader. Native uploads support font files up to 4 MB."
        )
        if canWrite {
          Button("Upload server font", action: openImport).disabled(busy)
            .accessibilityIdentifier("adminUploadFont")
        }
      }
      ForEach(fonts) { font in
        NavigationLink {
          AdministrationFontEditor(api: api, canWrite: canWrite, font: font)
        } label: {
          VStack(alignment: .leading) {
            Text(font.familyName)
            Text("\(Int(font.weight)) · \(font.style) · \(font.format)").font(.caption)
          }
        }.accessibilityIdentifier("adminFont_\(font.id)")
      }
    }.navigationTitle("Server fonts")
      .toolbar { Button("Reload", action: reload).disabled(busy) }
      .task { await load() }
      .fileImporter(isPresented: $importing, allowedContentTypes: [.font], onCompletion: selected)
  }
  private func openImport() { importing = true }
  private func reload() { Task { await load() } }
  private func load() async {
    guard user.hasPermission(.manageAppSettings), !busy else { return }
    busy = true
    defer { busy = false }
    do {
      fonts = try await api.boundedJSONOnline(
        "server-fonts", byteLimit: 512 * 1024, expectedStatus: 200)
      message = nil
    } catch {
      fonts = []
      message = error.localizedDescription
    }
  }
  private func selected(_ result: Result<URL, Error>) {
    guard canWrite, !busy else { return }
    Task {
      busy = true
      do {
        let url = try result.get()
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard (1...(4 * 1024 * 1024)).contains(size) else { throw ConnectionError.resourceTooLarge }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let _: FontUploadResult = try await api.boundedMultipart(
          "server-fonts/upload", filename: url.lastPathComponent, data: data)
        message = "Server font uploaded."
      } catch { message = error.localizedDescription }
      busy = false
      if case .success = result { await load() }
    }
  }
}

struct AdministrationFontEditor: View {
  let api: BookOrbitAPI
  let canWrite: Bool
  let font: UserFont
  @Environment(\.dismiss) private var dismiss
  @State private var family: String
  @State private var busy = false
  @State private var message: String?
  @State private var deleting = false
  init(api: BookOrbitAPI, canWrite: Bool, font: UserFont) {
    self.api = api
    self.canWrite = canWrite
    self.font = font
    _family = State(initialValue: font.familyName)
  }
  var body: some View {
    Form {
      AdministrationNotice(message: message)
      Section("Font") {
        TextField("Family name", text: $family).disabled(!canWrite)
          .accessibilityIdentifier("adminFontFamily")
        LabeledContent("Original file", value: font.originalFileName)
        if canWrite {
          Button("Save font", action: save).disabled(busy || family.isEmpty || family.count > 200)
            .accessibilityIdentifier("adminSaveFont")
          Button("Delete server font", role: .destructive, action: reviewDelete).disabled(busy)
        }
      }
    }.navigationTitle(font.familyName)
      .confirmationDialog("Delete this server font for every reader?", isPresented: $deleting) {
        Button("Delete server font", role: .destructive, action: remove)
        Button("Cancel", role: .cancel) {}
      }
  }
  private func save() {
    guard canWrite, !busy else { return }
    busy = true
    Task {
      defer { busy = false }
      do {
        try await api.sendEmpty(
          "server-fonts/\(font.id)", method: "PATCH",
          body: JSONEncoder().encode(["familyName": family]), expectedStatus: 200)
        message = "Font saved."
      } catch { message = error.localizedDescription }
    }
  }
  private func reviewDelete() { deleting = true }
  private func remove() {
    guard canWrite, !busy else { return }
    busy = true
    Task {
      defer { busy = false }
      do {
        try await api.sendEmpty("server-fonts/\(font.id)", method: "DELETE", expectedStatus: 204)
        dismiss()
      } catch { message = error.localizedDescription }
    }
  }
}
