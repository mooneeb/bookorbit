import SwiftUI
import UniformTypeIdentifiers

@MainActor @Observable
final class NativeCustomIconsModel {
  let api: BookOrbitAPI
  var items: [CustomIcon] = []
  var page = 0
  var total = 0
  var isBusy = false
  var error: String?
  init(api: BookOrbitAPI) { self.api = api }
  func load(page: Int = 0) async {
    await perform {
      let result: CustomIconPage = try await self.api.boundedJSON(
        "custom-icons/manage",
        query: [.init(name: "page", value: String(page)), .init(name: "size", value: "20")],
        byteLimit: 128 * 1024)
      self.items = result.items
      self.total = result.total
      self.page = page
    }
  }
  func rename(_ icon: CustomIcon, name: String) async {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= 120 else {
      error = "Enter an icon name between 1 and 120 characters."
      return
    }
    await perform {
      let updated: CustomIcon = try await self.api.boundedJSON(
        "custom-icons/\(icon.slug)", method: "PATCH", body: JSONEncoder().encode(["name": trimmed]))
      if let index = self.items.firstIndex(where: { $0.slug == icon.slug }) {
        self.items[index] = updated
      }
    }
  }
  func remove(_ icon: CustomIcon) async {
    await perform {
      try await self.api.sendEmpty(
        "custom-icons/\(icon.slug)", method: "DELETE", expectedStatus: 204)
      self.items.removeAll { $0.slug == icon.slug }
      self.total = max(0, self.total - 1)
    }
  }
  func upload(_ result: Result<[URL], Error>) async {
    await perform {
      guard let url = try result.get().first else { throw ConnectionError.invalidResponse }
      let access = url.startAccessingSecurityScopedResource()
      defer { if access { url.stopAccessingSecurityScopedResource() } }
      let values = try url.resourceValues(forKeys: [.fileSizeKey])
      guard let size = values.fileSize, size <= 128 * 1024 else {
        throw ConnectionError.resourceTooLarge
      }
      let response: CustomIconUploadResponse = try await self.api.boundedMultipart(
        "custom-icons", filename: "icon.svg", data: Data(contentsOf: url), fieldName: "files",
        mimeType: "image/svg+xml")
      guard let created = response.items.first?.icon else { throw ConnectionError.invalidResponse }
      self.items.insert(created, at: 0)
      self.items = Array(self.items.prefix(20))
      self.total += 1
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

struct NativeCustomIconsView: View {
  let canManage: Bool
  @State private var model: NativeCustomIconsModel
  @State private var choosingFile = false
  @State private var editing: CustomIcon?
  @State private var name = ""
  @State private var removing: CustomIcon?
  init(api: BookOrbitAPI, canManage: Bool) {
    self.canManage = canManage
    _model = State(initialValue: NativeCustomIconsModel(api: api))
  }
  var body: some View {
    List {
      Text(
        "Custom SVG icons belong to the server and can be used for libraries, collections, and smart scopes."
      )
      if canManage { Button("Upload SVG icon") { choosingFile = true }.disabled(model.isBusy) }
      ForEach(model.items, id: \.slug) { icon in
        VStack(alignment: .leading) {
          Text(icon.name).font(.headline)
          Text(icon.slug).font(.caption)
          if canManage {
            HStack {
              Button("Rename") {
                name = icon.name
                editing = icon
              }
              Button("Delete", role: .destructive) { removing = icon }
            }.buttonStyle(.borderless).disabled(model.isBusy)
          }
        }
      }
      HStack {
        Button("Previous") { Task { await model.load(page: model.page - 1) } }.disabled(
          model.page == 0 || model.isBusy)
        Spacer()
        Text("\(model.total) icons")
        Spacer()
        Button("Next") { Task { await model.load(page: model.page + 1) } }.disabled(
          (model.page + 1) * 20 >= model.total || model.isBusy)
      }
      if let error = model.error { Text(error).foregroundStyle(.red) }
      if model.isBusy { ProgressView("Loading icons") }
    }.navigationTitle("Custom icons").task { await model.load() }
      .fileImporter(
        isPresented: $choosingFile, allowedContentTypes: [.svg], allowsMultipleSelection: false
      ) { result in
        Task { await model.upload(result) }
      }
      .alert(
        "Rename icon",
        isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })
      ) {
        TextField("Name", text: $name)
        Button("Save") {
          if let icon = editing { Task { await model.rename(icon, name: name) } }
          editing = nil
        }
        Button("Cancel", role: .cancel) { editing = nil }
      }
      .confirmationDialog(
        "Delete this server icon?",
        isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })
      ) {
        Button("Delete", role: .destructive) {
          if let icon = removing { Task { await model.remove(icon) } }
          removing = nil
        }
      }
  }
}
