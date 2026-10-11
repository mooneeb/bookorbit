import SwiftUI

@MainActor @Observable
final class NativeNotificationsModel {
  let api: BookOrbitAPI
  var items: [NotificationItem] = []
  var total = 0
  var offset = 0
  var isBusy = false
  var error: String?
  init(api: BookOrbitAPI) { self.api = api }

  func load(offset: Int = 0) async {
    await perform {
      let page = try await self.api.personalNotifications(offset: offset)
      self.items = page.items
      self.total = page.total
      self.offset = offset
    }
  }

  func read(_ id: Int) async {
    await perform {
      try await self.api.markPersonalNotificationRead(id)
      if let index = self.items.firstIndex(where: { $0.id == id }) { self.items[index].read = true }
    }
  }

  func dismiss(_ id: Int) async {
    await perform {
      try await self.api.dismissPersonalNotification(id)
      self.items.removeAll { $0.id == id }
      self.total = max(0, self.total - 1)
    }
  }

  func readAll() async {
    await perform {
      try await self.api.markAllPersonalNotificationsRead()
      for index in self.items.indices { self.items[index].read = true }
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

struct NativeNotificationsView: View {
  let api: BookOrbitAPI
  let user: AuthUser
  let openBook: (Int) -> Void
  @State private var model: NativeNotificationsModel
  @Environment(\.openURL) private var openURL
  init(api: BookOrbitAPI, user: AuthUser, openBook: @escaping (Int) -> Void) {
    self.api = api
    self.user = user
    self.openBook = openBook
    _model = State(initialValue: NativeNotificationsModel(api: api))
  }

  var body: some View {
    List {
      Section {
        Button("Mark all read") { Task { await model.readAll() } }
          .disabled(model.isBusy).accessibilityIdentifier("markAllNotificationsRead")
        NavigationLink("Notification preferences") {
          NativeNotificationPreferencesView(api: api, user: user)
        }
      }
      if model.items.isEmpty && !model.isBusy {
        Text("No notifications").accessibilityIdentifier("notificationsEmpty")
      }
      ForEach(model.items, id: \.id) { item in
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Text(item.title).font(item.read ? .body : .headline)
            if !item.read {
              Image(systemName: "circle.fill").font(.caption2).accessibilityLabel("Unread")
            }
          }
          if let message = item.message { Text(message).font(.subheadline) }
          if item.count > 1 { Text("\(item.count) occurrences").font(.caption) }
          HStack {
            if item.actionUrl != nil {
              Button("Open") { open(item) }.accessibilityIdentifier("openNotification\(item.id)")
            }
            if !item.read { Button("Mark read") { Task { await model.read(item.id) } } }
            Button("Dismiss", role: .destructive) { Task { await model.dismiss(item.id) } }
          }.buttonStyle(.borderless).disabled(model.isBusy)
        }.padding(.vertical, 6)
      }
      HStack {
        Button("Previous") { Task { await model.load(offset: max(0, model.offset - 20)) } }
          .disabled(model.offset == 0 || model.isBusy)
        Spacer()
        Text("\(model.total) notifications")
        Spacer()
        Button("Next") { Task { await model.load(offset: model.offset + 20) } }
          .disabled(model.offset + 20 >= model.total || model.isBusy)
      }
      if let error = model.error {
        Text(error).foregroundStyle(.red)
        Button("Try again") { Task { await model.load(offset: model.offset) } }
      }
      if model.isBusy { ProgressView("Loading notifications") }
    }.navigationTitle("Notifications").task { await model.load() }
  }

  private func open(_ item: NotificationItem) {
    guard let action = item.actionUrl else { return }
    Task {
      if !item.read { await model.read(item.id) }
      guard model.error == nil else { return }
      let parts = action.split(separator: "/")
      if parts.count == 2, ["book", "books"].contains(String(parts[0])), let id = Int(parts[1]),
        id > 0
      {
        openBook(id)
      } else if action.hasPrefix("/"), !action.hasPrefix("//"),
        let url = URL(string: action, relativeTo: api.profile.url)?.absoluteURL
      {
        openURL(url)
      } else if let url = URL(string: action), url.scheme == "https" {
        openURL(url)
      }
    }
  }
}

struct NativeNotificationPreferencesView: View {
  let api: BookOrbitAPI
  @State private var preferences: [String: JSONValue]
  @State private var isBusy = false
  @State private var message: String?
  private let categories = [
    "scanning", "metadata", "bookDock", "bookRequests", "authorEnrichment", "email", "migration",
    "fileWriteBack", "fileRename", "bulkRename", "achievements", "podcasts",
  ]
  init(api: BookOrbitAPI, user: AuthUser) {
    self.api = api
    let data = try? JSONEncoder().encode(user.settings.notificationPreferences)
    _preferences = State(
      initialValue: data.flatMap { try? JSONDecoder().decode([String: JSONValue].self, from: $0) }
        ?? [:])
  }
  var body: some View {
    Form {
      ForEach(categories, id: \.self) { category in
        Picker(
          categoryLabel(category),
          selection: Binding(get: { level(category) }, set: { preferences[category] = .string($0) })
        ) {
          Text("Off").tag("off")
          if !["achievements", "bookDock"].contains(category) {
            Text("Problems only").tag("problems")
          }
          Text("All").tag("all")
        }
      }
      Button("Save notification preferences") { Task { await save() } }.disabled(isBusy)
      if let message { Text(message) }
      Text(
        "Notification delivery settings are shared with your account. System notification permission is managed in iPad Settings."
      )
    }.navigationTitle("Notification preferences")
  }
  private func level(_ category: String) -> String {
    switch preferences[category] {
    case .string(let value): value
    case .boolean(false): "off"
    default: "all"
    }
  }
  private func categoryLabel(_ category: String) -> String {
    category.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
      .capitalized
  }
  private func save() async {
    guard !isBusy else { return }
    isBusy = true
    defer { isBusy = false }
    do {
      try await api.saveAccountSettings(["notificationPreferences": .object(preferences)])
      message = "Notification preferences saved."
    } catch { message = error.localizedDescription }
  }
}
