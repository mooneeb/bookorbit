import SwiftUI

struct RequestAutomationView: View {
  let api: BookOrbitAPI
  @State private var settings: BookRequestAutomationSettings?
  @State private var busy = false
  @State private var error: String?
  @State private var saved = false
  @State private var autoGrab = false
  @State private var minScore: Double = 80
  @State private var retry = true
  @State private var attempts: Double = 3
  @State private var autoSearch = false
  @State private var interval: Double = 24
  @State private var maxAge: Double = 60
  @State private var verify = true
  @State private var threshold: Double = 70
  @State private var formats = "all"
  @State private var libraryIDs = ["ebook": "", "audiobook": "", "comic": ""]
  @State private var folderIDs = ["ebook": "", "audiobook": "", "comic": ""]
  @State private var profiles: [String: [ReleaseTier]] = [
    "ebook": [], "audiobook": [], "comic": [],
  ]
  @State private var libraries: [Library] = []
  @State private var sources: [IndexerItem] = []

  var body: some View {
    Form {
      Section("Automatic releases") {
        Toggle("Automatically grab releases", isOn: $autoGrab)
        Stepper("Minimum score: \(Int(minScore))", value: $minScore, in: 50...100)
        Toggle("Retry failed automatic downloads", isOn: $retry)
        Stepper("Maximum attempts: \(Int(attempts))", value: $attempts, in: 1...10)
      }
      Section("Periodic searches") {
        Toggle("Search approved requests again", isOn: $autoSearch)
        Stepper("Interval: \(Int(interval)) hours", value: $interval, in: 1...168)
        Stepper("Maximum request age: \(Int(maxAge)) days", value: $maxAge, in: 1...365)
      }
      Section("Import verification") {
        Toggle("Verify imported books", isOn: $verify)
        Stepper("Verification threshold: \(Int(threshold))", value: $threshold, in: 0...100)
        Picker("Keep formats", selection: $formats) {
          Text("All formats").tag("all")
          Text("Preferred format").tag("preferred")
        }.pickerStyle(.menu).accessibilityIdentifier("requestAutomationFormats")
      }
      Section("Default destinations") {
        ForEach(["ebook", "audiobook", "comic"], id: \.self) { kind in
          Picker("\(kind.capitalized) library", selection: libraryBinding(kind)) {
            Text("No default destination").tag(0)
            ForEach(libraries.filter { $0.type == "books" }) { library in
              Text(library.name).tag(library.id)
            }
            if let id = Int(libraryIDs[kind] ?? ""), !libraries.contains(where: { $0.id == id }) {
              Text("Existing destination unavailable").tag(id)
            }
          }
          .pickerStyle(.menu).accessibilityIdentifier("requestAutomationLibrary\(kind)")
          if let libraryID = Int(libraryIDs[kind] ?? ""),
            let library = libraries.first(where: { $0.id == libraryID })
          {
            Picker("\(kind.capitalized) folder", selection: folderBinding(kind)) {
              Text("First library folder").tag(0)
              ForEach(library.folders ?? []) { folder in Text(folder.path).tag(folder.id) }
            }
          }
        }
      }
      Section("Release profiles") {
        ForEach(["ebook", "audiobook", "comic"], id: \.self) { kind in
          NavigationLink("\(kind.capitalized) tiers") {
            RequestReleaseProfileEditor(
              tiers: Binding(get: { profiles[kind] ?? [] }, set: { profiles[kind] = $0 }),
              sources: sources, medium: kind)
          }
        }
      }
      if let error {
        Section {
          Text(error).accessibilityIdentifier("requestAdminError")
          if settings == nil { Button("Retry", action: reload) }
        }
      }
      if saved {
        Text("Automation settings saved.").accessibilityIdentifier("requestAutomationSaved")
      }
      if busy { ProgressView("Updating automation") }
      Button("Save automation", action: save).accessibilityIdentifier("requestAutomationSave")
        .disabled(settings == nil || busy)
    }
    .navigationTitle("Request automation")
    .disabled(busy)
    .task { await load() }
  }
  private func libraryBinding(_ key: String) -> Binding<Int> {
    Binding(
      get: { Int(libraryIDs[key] ?? "") ?? 0 },
      set: {
        libraryIDs[key] = $0 == 0 ? "" : String($0)
        folderIDs[key] = ""
      })
  }
  private func folderBinding(_ key: String) -> Binding<Int> {
    Binding(
      get: { Int(folderIDs[key] ?? "") ?? 0 }, set: { folderIDs[key] = $0 == 0 ? "" : String($0) })
  }
  private func reload() { Task { await load() } }
  private func load() async {
    guard !busy else { return }
    busy = true
    error = nil
    defer { busy = false }
    do {
      async let directory: [Library] = api.boundedJSON("libraries")
      async let sourceDirectory = api.requestSources()
      let value = try await api.requestAutomation()
      let loadedLibraries = try await directory
      let loadedSources = try await sourceDirectory.indexers
      settings = value
      libraries = loadedLibraries
      sources = loadedSources
      autoGrab = value.autoGrabEnabled
      minScore = value.autoGrabMinScore
      retry = value.autoRetryEnabled
      attempts = value.maxAutoGrabAttempts
      autoSearch = value.autoSearchEnabled
      interval = value.autoSearchIntervalHours
      maxAge = value.autoSearchMaxAgeDays
      verify = value.verificationEnabled
      threshold = value.verificationThreshold
      formats = value.importFormats
      if let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
        as? [String: Any]
      {
        let destinations = object["destinations"] as? [String: [String: Any]] ?? [:]
        let profileObject = object["profiles"] as? [String: Any] ?? [:]
        for kind in ["ebook", "audiobook", "comic"] {
          libraryIDs[kind] = (destinations[kind]?["libraryId"] as? NSNumber)?.stringValue ?? ""
          folderIDs[kind] = (destinations[kind]?["folderId"] as? NSNumber)?.stringValue ?? ""
          if let profile = profileObject[kind] {
            profiles[kind] = try JSONDecoder().decode(
              [ReleaseTier].self, from: JSONSerialization.data(withJSONObject: profile))
          }
        }
      }
    } catch { self.error = error.localizedDescription }
  }
  private func save() {
    Task {
      guard !busy else { return }
      busy = true
      error = nil
      saved = false
      defer { busy = false }
      do {
        var destinations: [String: Any] = [:]
        var profilePayload: [String: Any] = [:]
        for kind in ["ebook", "audiobook", "comic"] {
          let libraryText = libraryIDs[kind] ?? ""
          let folderText = folderIDs[kind] ?? ""
          if (!libraryText.isEmpty && (Int(libraryText) ?? 0) <= 0)
            || (!folderText.isEmpty && (Int(folderText) ?? 0) <= 0)
          {
            throw ConnectionError.invalidResponse
          }
          destinations[kind] = [
            "libraryId": Int(libraryText).map { $0 as Any } ?? NSNull(),
            "folderId": Int(folderText).map { $0 as Any } ?? NSNull(),
          ]
          profilePayload[kind] = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(profiles[kind] ?? []))
        }
        let body: [String: Any] = [
          "autoGrabEnabled": autoGrab, "autoGrabMinScore": Int(minScore), "autoRetryEnabled": retry,
          "maxAutoGrabAttempts": Int(attempts), "autoSearchEnabled": autoSearch,
          "autoSearchIntervalHours": Int(interval), "autoSearchMaxAgeDays": Int(maxAge),
          "verificationEnabled": verify, "verificationThreshold": Int(threshold),
          "importFormats": formats, "destinations": destinations, "profiles": profilePayload,
        ]
        settings = try await api.saveRequestAutomation(
          body: JSONSerialization.data(withJSONObject: body))
        saved = true
      } catch { self.error = error.localizedDescription }
    }
  }
}
