import SwiftUI

struct AdministrationAuditView: View {
  let api: BookOrbitAPI
  let user: AuthUser
  @State private var entries: [AuditLogEntry] = []
  @State private var page = 1
  @State private var total = 0
  @State private var search = ""
  @State private var busy = false
  @State private var message: String?

  var body: some View {
    List {
      AdministrationNotice(message: message)
      Section {
        TextField("Search audit history", text: $search).onSubmit(searchEntries)
          .accessibilityIdentifier("adminAuditSearch")
        Button("Search", action: searchEntries).disabled(busy)
        Text("\(total) entries. Page \(page).")
      }
      ForEach(entries) { entry in
        VStack(alignment: .leading, spacing: 4) {
          Text(entry.description).fixedSize(horizontal: false, vertical: true)
          Text("\(entry.actorUsername) · \(entry.action)").font(.caption)
          Text(entry.createdAt).font(.caption).foregroundStyle(.secondary)
        }.accessibilityIdentifier("adminAudit_\(entry.id)")
      }
      Section {
        HStack {
          Button("Previous", action: previous).disabled(busy || page == 1)
          Spacer()
          Button("Next", action: next).disabled(busy || page * 50 >= total)
        }
      }
    }.navigationTitle("Audit history")
      .toolbar { Button("Reload", action: reload).disabled(busy) }
      .task { await load() }
  }
  private func reload() { Task { await load() } }
  private func searchEntries() {
    page = 1
    reload()
  }
  private func previous() {
    page -= 1
    reload()
  }
  private func next() {
    page += 1
    reload()
  }
  private func load() async {
    guard user.hasPermission(.viewAuditLog), !busy else { return }
    busy = true
    defer { busy = false }
    do {
      let result = try await api.administrationAudit(page: page, search: String(search.prefix(200)))
      entries = result.data
      total = result.total
      message = nil
    } catch {
      entries = []
      message = error.localizedDescription
    }
  }
}
