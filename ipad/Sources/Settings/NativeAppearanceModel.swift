import Foundation
import Observation
import SwiftUI

@MainActor @Observable
final class NativeAppearanceModel {
  var theme = "system"
  var accent = "blue"
  var background = "none"
  var layout = "list"
  var language = "en"
  var synchronize = false
  var isBusy = false
  var error: String?
  var savedMessage: String?
  var accountWarning: String?
  private let key: String
  private let api: BookOrbitAPI
  private var remoteTheme: [String: JSONValue] = [:]

  init(api: BookOrbitAPI, user: AuthUser) {
    self.api = api
    key = "personalization.\(api.profile.url.absoluteString).user.\(user.id)"
    synchronize = user.settings.syncThemePreferences ?? true
    if let data = UserDefaults.standard.data(forKey: key),
      let local = try? JSONDecoder().decode([String: JSONValue].self, from: data)
    {
      receive(local)
    }
  }

  var colorScheme: ColorScheme? {
    theme == "light" ? .light : theme == "dark" ? .dark : nil
  }

  var tint: Color {
    switch accent {
    case "green", "emerald", "mint": .green
    case "orange", "amber", "copper": .orange
    case "purple", "violet", "iris": .purple
    case "pink", "rose", "fuchsia": .pink
    case "grey", "white": .gray
    case "scarlet", "vermilion": .red
    default: .blue
    }
  }

  func load() async {
    guard !isBusy else { return }
    isBusy = true
    defer { isBusy = false }
    do {
      let locale = try await api.personalPreferences("locale")
      if case .string(let value) = locale?["locale"] { language = value }
      if synchronize, let theme = try await api.personalPreferences("theme") {
        remoteTheme = theme
        receive(theme)
      }
      persist()
    } catch { self.error = error.localizedDescription }
  }

  func save() async {
    guard !isBusy else { return }
    isBusy = true
    error = nil
    savedMessage = nil
    accountWarning = nil
    defer { isBusy = false }
    persist()
    savedMessage = "Appearance saved on this iPad."
    do {
      if synchronize {
        var settings = remoteTheme
        settings["theme"] = .string(theme)
        settings["accent"] = .string(accent)
        settings["background"] = .string(background)
        settings["radius"] = settings["radius"] ?? .string("default")
        settings["brightness"] = settings["brightness"] ?? .number(35)
        try await api.savePersonalPreferences("theme", settings: settings)
        remoteTheme = settings
      }
      try await api.savePersonalPreferences("locale", settings: ["locale": .string(language)])
      try await api.sendEmpty(
        "users/me/theme-storage-mode", method: "PATCH",
        body: JSONEncoder().encode(["sync": synchronize]), expectedStatus: 204)
      persist()
      savedMessage =
        "Appearance saved. Language is shared with your account. Layout stays on this iPad."
    } catch {
      accountWarning = "Account preferences could not be updated: \(error.localizedDescription)"
    }
  }

  private func receive(_ settings: [String: JSONValue]) {
    if case .string(let value) = settings["theme"], ["light", "dark", "system"].contains(value) {
      theme = value
    }
    if case .string(let value) = settings["accent"] { accent = value }
    if case .string(let value) = settings["background"] { background = value }
    if case .string(let value) = settings["layout"], ["grid", "list", "table"].contains(value) {
      layout = value
    }
    if case .string(let value) = settings["locale"] { language = value }
    if case .boolean(let value) = settings["synchronize"] { synchronize = value }
  }

  private func persist() {
    let settings: [String: JSONValue] = [
      "theme": .string(theme), "accent": .string(accent), "background": .string(background),
      "layout": .string(layout), "locale": .string(language),
      "synchronize": .boolean(synchronize),
    ]
    if let data = try? JSONEncoder().encode(settings) {
      UserDefaults.standard.set(data, forKey: key)
    }
  }
}

struct NativeAppearanceBackground: View {
  let pattern: String
  var body: some View {
    Canvas { context, size in
      guard pattern != "none" else { return }
      let step: CGFloat = pattern == "millimeter" ? 12 : 28
      for x in stride(from: CGFloat.zero, through: size.width, by: step) {
        for y in stride(from: CGFloat.zero, through: size.height, by: step) {
          var path = Path()
          if pattern == "dots" {
            path.addEllipse(in: CGRect(x: x, y: y, width: 2, height: 2))
          } else {
            path.move(to: CGPoint(x: x - 3, y: y))
            path.addLine(to: CGPoint(x: x + 3, y: y))
            path.move(to: CGPoint(x: x, y: y - 3))
            path.addLine(to: CGPoint(x: x, y: y + 3))
          }
          context.stroke(path, with: .color(.secondary.opacity(0.15)), lineWidth: 1)
        }
      }
    }.allowsHitTesting(false).accessibilityHidden(true)
  }
}
