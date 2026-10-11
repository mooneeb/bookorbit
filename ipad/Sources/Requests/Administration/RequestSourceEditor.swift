import CoreFoundation
import SwiftUI

struct RequestSourceEditor: View {
  @Bindable var model: RequestAdministrationModel
  let source: IndexerItem?
  @Environment(\.dismiss) private var dismiss
  @State private var color: String
  @State private var network: RequestNetworkProfileDraft
  @State private var name: String
  @State private var adapter: String
  @State private var baseURL: String
  @State private var credential = ""
  @State private var replaceCredential = false
  @State private var enabled: Bool
  @State private var privateAddress: Bool
  @State private var isbnDisabled: Bool
  @State private var ebookCategories: String
  @State private var audiobookCategories: String
  @State private var comicCategories: String
  @State private var settings: [String: String] = [:]
  @State private var disabledMedia: Set<String>
  @State private var trackerSeedGoals: Bool
  @State private var seedRatio: String
  @State private var seedMinutes: String

  init(model: RequestAdministrationModel, source: IndexerItem?) {
    self.model = model
    self.source = source
    _color = State(initialValue: source?.color ?? "")
    _network = State(
      initialValue: RequestNetworkProfileDraft(
        resolvers: source?.networkProfile?.resolvers, proxyURL: source?.networkProfile?.proxyUrl))
    _name = State(initialValue: source?.name ?? "")
    _adapter = State(initialValue: source?.adapterType ?? model.adapters.first?.type ?? "torznab")
    _baseURL = State(initialValue: source?.baseUrl ?? "")
    _enabled = State(initialValue: source?.enabled ?? true)
    _privateAddress = State(initialValue: source?.allowPrivateAddress ?? false)
    _isbnDisabled = State(initialValue: source?.isbnSearchDisabled ?? false)
    _ebookCategories = State(
      initialValue: source?.categories.ebook.map { String(Int($0)) }.joined(separator: ",")
        ?? "7020")
    _audiobookCategories = State(
      initialValue: source?.categories.audiobook.map { String(Int($0)) }.joined(separator: ",")
        ?? "3030")
    _comicCategories = State(
      initialValue: source?.categories.comic.map { String(Int($0)) }.joined(separator: ",")
        ?? "7030")
    _disabledMedia = State(initialValue: Set(source?.disabledMediaKinds ?? []))
    _trackerSeedGoals = State(initialValue: source?.applyTrackerSeedGoals ?? true)
    _seedRatio = State(initialValue: source?.seedRatioGoal.map { String($0) } ?? "")
    _seedMinutes = State(initialValue: source?.seedTimeMinutes.map { String(Int($0)) } ?? "")
  }

  private var descriptor: IndexerAdapterDescriptor? { model.adapters.first { $0.type == adapter } }
  var body: some View {
    Form {
      Section("Connection") {
        TextField("Source name", text: $name).accessibilityIdentifier("requestSourceName")
        Picker("Adapter", selection: $adapter) {
          ForEach(model.adapters, id: \.type) { Text($0.label).tag($0.type) }
        }.disabled(source != nil)
        TextField("Base URL", text: $baseURL).textInputAutocapitalization(.never)
          .autocorrectionDisabled().keyboardType(.URL).accessibilityIdentifier("requestSourceURL")
        RequestColorPicker(selection: $color, identifier: "requestSourceColor")
        Toggle("Enabled", isOn: $enabled)
        Toggle("Allow private network address", isOn: $privateAddress).accessibilityIdentifier(
          "requestSourcePrivateAddress")
        if source?.hasCredential == true {
          Toggle("Replace stored credential", isOn: $replaceCredential)
        }
        if source?.hasCredential != true || replaceCredential {
          SecureField(
            descriptor?.credentialKind == "sessionId" ? "Session ID" : "API key", text: $credential
          ).accessibilityIdentifier("requestSourceCredential")
            .disabled(!model.encryptionConfigured)
        }
        if replaceCredential { Text("An empty value clears the stored credential.").font(.caption) }
      }
      if descriptor?.usesCategories == true {
        Section("Categories") {
          TextField("Ebook category IDs", text: $ebookCategories)
          TextField("Audiobook category IDs", text: $audiobookCategories)
          TextField("Comic category IDs", text: $comicCategories)
        }
      }
      Section("Search") {
        ForEach(["ebook", "audiobook", "comic"], id: \.self) { kind in
          Toggle(
            "Search \(kind)",
            isOn: Binding(
              get: { !disabledMedia.contains(kind) },
              set: { if $0 { disabledMedia.remove(kind) } else { disabledMedia.insert(kind) } }))
        }
        if descriptor?.supportsIsbnSearch == true {
          Toggle("Disable ISBN search", isOn: $isbnDisabled)
        }
      }
      if descriptor?.seedsBack == true {
        Section("Seed goals") {
          Toggle("Use tracker seed goals", isOn: $trackerSeedGoals)
          TextField("Seed ratio", text: $seedRatio).keyboardType(.decimalPad)
          TextField("Seed minutes", text: $seedMinutes).keyboardType(.numberPad)
        }
      }
      if let fields = descriptor?.settingsFields, !fields.isEmpty {
        Section("Adapter settings") {
          ForEach(fields, id: \.key) { field in
            if field.type == "boolean" {
              Toggle(
                field.label,
                isOn: Binding(
                  get: { settings[field.key] == "true" }, set: { settings[field.key] = String($0) })
              )
            } else {
              TextField(
                field.label,
                text: Binding(get: { settings[field.key] ?? "" }, set: { settings[field.key] = $0 })
              )
            }
            if let hint = field.hint { Text(hint).font(.caption).foregroundStyle(.secondary) }
          }
        }
      }
      RequestNetworkProfileFields(draft: $network)
      if let error = model.error {
        Section { Text(error).accessibilityIdentifier("requestAdminError") }
      }
      Button("Save source", action: save).accessibilityIdentifier("requestSourceSave").disabled(
        name.isEmpty || baseURL.isEmpty || model.busy)
    }
    .navigationTitle(source == nil ? "Add source" : "Edit source")
    .disabled(model.busy)
    .onAppear(perform: initializeSettings)
  }

  private func initializeSettings() {
    guard settings.isEmpty else { return }
    if let source, let data = try? JSONEncoder().encode(source),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let values = object["settings"] as? [String: Any]
    {
      for (key, value) in values {
        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
          settings[key] = number.boolValue ? "true" : "false"
        } else {
          settings[key] = String(describing: value)
        }
      }
    }
    for field in descriptor?.settingsFields ?? [] where settings[field.key] == nil {
      if let value = field.default, let encoded = try? JSONEncoder().encode(value),
        let string = String(data: encoded, encoding: .utf8)
      {
        settings[field.key] = string.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
      }
    }
  }

  private func categories(_ text: String) throws -> [Int] {
    if text.trimmingCharacters(in: .whitespaces).isEmpty { return [] }
    let tokens = text.split(separator: ",")
    let values = tokens.compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    guard values.count == tokens.count, values.count <= 30, values.allSatisfy({ $0 >= 0 }) else {
      throw ConnectionError.invalidResponse
    }
    return values
  }

  private func save() {
    Task {
      guard !model.busy else { return }
      await model.perform {
        var body: [String: Any] = [
          "name": name, "adapterType": adapter, "baseUrl": baseURL, "enabled": enabled,
          "allowPrivateAddress": privateAddress, "isbnSearchDisabled": isbnDisabled,
          "disabledMediaKinds": Array(disabledMedia),
        ]
        body["color"] = color.isEmpty ? NSNull() : color as Any
        body["networkProfile"] = try network.jsonObject()
        if source == nil || replaceCredential { body["credential"] = credential }
        if descriptor?.usesCategories == true {
          body["categories"] = [
            "ebook": try categories(ebookCategories),
            "audiobook": try categories(audiobookCategories),
            "comic": try categories(comicCategories),
          ]
        }
        if descriptor?.seedsBack == true {
          body["applyTrackerSeedGoals"] = trackerSeedGoals
          if !seedRatio.isEmpty {
            guard let ratio = Double(seedRatio), ratio > 0 else {
              throw ConnectionError.invalidResponse
            }
            body["seedRatioGoal"] = ratio
          } else {
            body["seedRatioGoal"] = NSNull()
          }
          if !seedMinutes.isEmpty {
            guard let minutes = Int(seedMinutes), minutes > 0 else {
              throw ConnectionError.invalidResponse
            }
            body["seedTimeMinutes"] = minutes
          } else {
            body["seedTimeMinutes"] = NSNull()
          }
        }
        var values: [String: Any] = [:]
        for field in descriptor?.settingsFields ?? [] {
          let value = settings[field.key] ?? ""
          switch field.type {
          case "boolean": values[field.key] = value == "true"
          case "number":
            guard let number = Double(value), number.isFinite else {
              throw ConnectionError.invalidResponse
            }
            values[field.key] = number
          default: values[field.key] = value
          }
        }
        body["settings"] = values
        _ = try await model.api.saveRequestSource(
          id: source?.id, body: JSONSerialization.data(withJSONObject: body))
        credential = ""
      }
      if model.error == nil {
        await model.load()
        dismiss()
      }
    }
  }
}

struct RequestColorPicker: View {
  @Binding var selection: String
  let identifier: String
  private let colors = [
    "blue", "indigo", "purple", "pink", "red", "orange", "yellow", "lime", "green", "teal",
  ]

  var body: some View {
    Picker("Color", selection: $selection) {
      Text("Automatic").tag("")
      ForEach(colors, id: \.self) { color in
        Label(color.capitalized, systemImage: "circle.fill")
          .foregroundStyle(tint(color)).tag(color)
      }
    }.pickerStyle(.menu).accessibilityIdentifier(identifier)
  }

  private func tint(_ color: String) -> Color {
    switch color {
    case "blue": .blue
    case "indigo": .indigo
    case "purple": .purple
    case "pink": .pink
    case "red": .red
    case "orange": .orange
    case "yellow": .yellow
    case "lime", "green": .green
    case "teal": .teal
    default: .primary
    }
  }
}

struct RequestNetworkProfileDraft {
  var resolvers: String
  var proxyURL: String

  init(resolvers: [String]? = nil, proxyURL: String? = nil) {
    self.resolvers = resolvers?.joined(separator: ",") ?? ""
    self.proxyURL = proxyURL ?? ""
  }

  func jsonObject() throws -> Any {
    let addresses = resolvers.split(separator: ",", omittingEmptySubsequences: false)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    let values = resolvers.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : addresses
    let proxy = proxyURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard values.count <= 4, values.allSatisfy({ !$0.isEmpty }) else {
      throw RequestNetworkProfileError.invalidResolvers
    }
    if !proxy.isEmpty {
      guard let url = URL(string: proxy),
        ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
        url.host != nil, proxy.count <= 2048
      else { throw RequestNetworkProfileError.invalidProxy }
    }
    guard !values.isEmpty || !proxy.isEmpty else { return NSNull() }
    let profile = UpdateIndexerPayloadNetworkProfile(
      resolvers: values.isEmpty ? nil : values, proxyUrl: proxy.isEmpty ? nil : proxy)
    return try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile))
  }
}

struct RequestNetworkProfileFields: View {
  @Binding var draft: RequestNetworkProfileDraft
  var body: some View {
    Section("Network profile") {
      TextField("DNS resolver IP addresses", text: $draft.resolvers)
        .textInputAutocapitalization(.never).autocorrectionDisabled()
        .accessibilityIdentifier("requestNetworkResolvers")
      Text(
        "Use up to four IP addresses, separated by commas. Leave empty to use the server resolver."
      )
      .font(.caption).foregroundStyle(.secondary)
      TextField("HTTP proxy URL", text: $draft.proxyURL)
        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
        .accessibilityIdentifier("requestNetworkProxy")
      Text("Leave empty for a direct connection. The private address policy still applies.")
        .font(.caption).foregroundStyle(.secondary)
    }
  }
}

private enum RequestNetworkProfileError: LocalizedError {
  case invalidResolvers, invalidProxy
  var errorDescription: String? {
    switch self {
    case .invalidResolvers: "Enter up to four DNS resolver IP addresses, separated by commas."
    case .invalidProxy: "Enter an HTTP or HTTPS proxy URL with a hostname."
    }
  }
}
