import SwiftUI

struct AdministrationLibrariesView: View {
  let api: BookOrbitAPI
  let user: AuthUser
  @State private var libraries: [Library] = []
  @State private var message: String?
  @State private var busy = false
  @State private var creating = false

  var body: some View {
    List {
      AdministrationNotice(message: message)
      ForEach(libraries) { library in
        NavigationLink {
          AdministrationLibraryEditor(api: api, user: user, library: library)
        } label: {
          VStack(alignment: .leading) {
            Text(library.name)
            Text("\(library.bookCount ?? 0) books · \(library.accessLevel ?? "superuser")")
              .font(.caption).foregroundStyle(.secondary)
          }
        }.accessibilityIdentifier("adminLibrary_\(library.id)")
      }
      if libraries.isEmpty && !busy { Text("No accessible libraries.") }
    }.navigationTitle("Libraries and automation")
      .toolbar {
        Button("Create library", action: create).disabled(busy)
          .accessibilityIdentifier("adminCreateLibrary")
        Button("Reload", action: reload).disabled(busy)
      }
      .sheet(isPresented: $creating, onDismiss: reload) {
        NavigationStack { AdministrationLibraryEditor(api: api, user: user, library: nil) }
      }
      .task { await load() }
  }

  private func create() { creating = true }
  private func reload() { Task { await load() } }
  private func load() async {
    guard user.hasPermission(.manageLibraries), !busy else { return }
    busy = true
    defer { busy = false }
    do {
      libraries = try await api.administrationLibraries()
      message = nil
    } catch {
      libraries = []
      message = error.localizedDescription
    }
  }
}

struct AdministrationLibraryEditor: View {
  let api: BookOrbitAPI
  let user: AuthUser
  let library: Library?
  @Environment(\.dismiss) private var dismiss
  @State private var name: String
  @State private var folder = ""
  @State private var watch: Bool
  @State private var organization: String
  @State private var cron: String
  @State private var pattern: String
  @State private var writeEnabled: Bool
  @State private var renameEnabled: Bool
  @State private var busy = false
  @State private var message: String?
  @State private var deleting = false

  init(api: BookOrbitAPI, user: AuthUser, library: Library?) {
    self.api = api
    self.user = user
    self.library = library
    _name = State(initialValue: library?.name ?? "")
    _watch = State(initialValue: library?.watch ?? false)
    _organization = State(initialValue: library?.organizationMode ?? "book_per_file")
    _cron = State(initialValue: library?.autoScanCronExpression ?? "")
    _pattern = State(initialValue: library?.fileNamingPattern ?? "")
    _writeEnabled = State(initialValue: library?.fileWriteEnabled ?? false)
    _renameEnabled = State(initialValue: library?.fileRenameEnabled ?? false)
  }

  private var canEdit: Bool {
    user.hasPermission(.manageLibraries)
      && (library == nil || user.isSuperuser
        || ["owner", "editor"].contains(library?.accessLevel ?? ""))
  }
  private var canDelete: Bool {
    user.hasPermission(.manageLibraries) && library != nil
      && (user.isSuperuser || library?.accessLevel == "owner")
  }

  var body: some View {
    Form {
      AdministrationNotice(message: message)
      Section("Library") {
        TextField("Name", text: $name).accessibilityIdentifier("adminLibraryName")
        if let library {
          ForEach(library.folders ?? []) { folder in Text(folder.path).textSelection(.enabled) }
          if library.type == "books" {
            NavigationLink {
              LibraryScanView(api: api, user: user, library: library)
            } label: {
              Text("Preview and run a scan")
            }
            .accessibilityIdentifier("adminLibraryScan")
          }
        } else {
          TextField("Absolute server folder", text: $folder)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .accessibilityIdentifier("adminLibraryFolder")
        }
      }
      if library?.type != "podcasts" {
        Section("Organization and automation") {
          Picker("Organization", selection: $organization) {
            Text("One book per file").tag("book_per_file")
            Text("One book per folder").tag("book_per_folder")
          }.disabled(library != nil).accessibilityIdentifier("adminLibraryOrganization")
          if library != nil {
            Text("Organization is fixed when a library is created.").font(.caption)
          }
          Toggle("Watch server folders", isOn: $watch).accessibilityIdentifier("adminLibraryWatch")
          TextField("Scan schedule (cron, optional)", text: $cron)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .accessibilityIdentifier("adminLibraryCron")
          Text(
            "Use a five-field cron schedule in server time, or leave empty to disable scheduled scans."
          )
          .font(.caption)
        }
        Section("File naming and writeback") {
          TextField("Naming pattern (optional)", text: $pattern)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .accessibilityIdentifier("adminLibraryNamingPattern")
          Toggle("Write metadata to source files", isOn: $writeEnabled)
            .accessibilityIdentifier("adminLibraryWriteEnabled")
          Toggle("Rename source files", isOn: $renameEnabled)
            .accessibilityIdentifier("adminLibraryRenameEnabled")
          Text(
            "These server settings govern future ingestion and file operations. Review per-format limits and existing files before running bulk writeback."
          )
          .font(.caption)
        }
      }
      if canEdit {
        Section {
          Button("Save library", action: save).disabled(
            busy || name.trimmingCharacters(in: .whitespaces).isEmpty
              || (library == nil && !folder.hasPrefix("/"))
          )
          .accessibilityIdentifier("adminSaveLibrary")
        }
      } else {
        Section { Text("Editor or owner access is required to configure this library.") }
      }
      if canDelete {
        Section {
          Button("Delete library", role: .destructive, action: reviewDelete).disabled(busy)
            .accessibilityIdentifier("adminDeleteLibrary")
        }
      }
    }.disabled(busy || !canEdit).navigationTitle(library?.name ?? "Create library")
      .confirmationDialog(
        "Delete this library and its catalog? Server source files are retained.",
        isPresented: $deleting
      ) {
        Button("Delete library", role: .destructive, action: remove)
        Button("Cancel", role: .cancel) {}
      }
  }

  private func save() {
    guard canEdit, !busy else { return }
    busy = true
    Task {
      defer { busy = false }
      do {
        var values: [String: JSONValue] = [
          "name": .string(name), "watch": .boolean(watch),
          "organizationMode": .string(organization),
          "autoScanCronExpression": cron.isEmpty ? .null : .string(cron),
          "fileNamingPattern": pattern.isEmpty ? .null : .string(pattern),
          "fileWriteEnabled": .boolean(writeEnabled), "fileRenameEnabled": .boolean(renameEnabled),
        ]
        if library == nil {
          values["icon"] = .string("lucide:library")
          values["folders"] = .array([.string(folder)])
        }
        if library?.type == "podcasts" {
          values = ["name": .string(name)]
        }
        let saved = try await api.saveAdministrationLibrary(id: library?.id, values: values)
        message = "Library saved: \(saved.name)."
        if library == nil { dismiss() }
      } catch { message = error.localizedDescription }
    }
  }
  private func reviewDelete() { deleting = true }
  private func remove() {
    guard canDelete, let library, !busy else { return }
    busy = true
    Task {
      defer { busy = false }
      do {
        try await api.sendEmpty("libraries/\(library.id)", method: "DELETE", expectedStatus: 204)
        dismiss()
      } catch { message = error.localizedDescription }
    }
  }
}
