import SwiftUI

struct RequestReleaseProfileEditor: View {
  @Binding var tiers: [ReleaseTier]
  let sources: [IndexerItem]
  let medium: String

  var body: some View {
    List {
      Section {
        Text(
          "Preferred tiers appear first. A release matching no tier requires manual approval. An empty list uses the normal score."
        ).font(.caption)
        ForEach($tiers) { $tier in
          NavigationLink {
            RequestReleaseTierEditor(tier: $tier, sources: sources, medium: medium)
          } label: {
            Text(tier.name.isEmpty ? "Unnamed tier" : tier.name)
          }
        }
        .onMove(perform: move)
        .onDelete(perform: remove)
        Button("Add tier", action: add).disabled(tiers.count >= 12)
      }
    }
    .navigationTitle("\(medium.capitalized) release profile")
    .toolbar { EditButton() }
  }
  private func move(_ source: IndexSet, _ destination: Int) {
    tiers.move(fromOffsets: source, toOffset: destination)
  }
  private func remove(_ source: IndexSet) { tiers.remove(atOffsets: source) }
  private func add() {
    tiers.append(
      ReleaseTier(
        id: UUID().uuidString, name: "New tier",
        conditions: ReleaseTierConditions(
          formats: nil, fileLayout: nil, minBitrateKbps: nil, channels: nil, languages: nil,
          indexerIds: nil, minSeeders: nil, maxSizeBytes: nil, freeleechOnly: nil,
          excludeVipOnly: nil)))
  }
}

private struct RequestReleaseTierEditor: View {
  @Binding var tier: ReleaseTier
  let sources: [IndexerItem]
  let medium: String

  var body: some View {
    Form {
      TextField("Tier name", text: $tier.name)
      Section("Formats") {
        ForEach(BookFileVocabulary.formats, id: \.self) { format in
          Toggle(format.uppercased(), isOn: selection($tier.conditions.formats, format))
        }
      }
      Section("File layout") {
        Picker(
          "Layout",
          selection: Binding(
            get: { tier.conditions.fileLayout ?? "" },
            set: { tier.conditions.fileLayout = $0.isEmpty ? nil : $0 })
        ) {
          Text("Any").tag("")
          Text("Single file").tag("single")
          Text("Multiple files").tag("multi")
        }
        if medium == "audiobook" {
          number("Minimum bitrate (kbps)", value: $tier.conditions.minBitrateKbps, minimum: 0)
          Picker(
            "Channels",
            selection: Binding(
              get: { tier.conditions.channels ?? 0 },
              set: { tier.conditions.channels = $0 == 0 ? nil : $0 })
          ) {
            Text("Any").tag(0.0)
            Text("Mono").tag(1.0)
            Text("Stereo").tag(2.0)
          }
        }
      }
      Section("Languages") {
        ForEach(BookRequestLanguageVocabulary.codes, id: \.self) { code in
          Toggle(
            Locale.current.localizedString(forLanguageCode: code) ?? code,
            isOn: selection($tier.conditions.languages, code))
        }
      }
      Section("Sources") {
        ForEach(sources) { source in
          Toggle(
            source.name,
            isOn: Binding(
              get: { tier.conditions.indexerIds?.contains(source.id) == true },
              set: { selected in
                var ids = tier.conditions.indexerIds ?? []
                if selected {
                  if !ids.contains(source.id) { ids.append(source.id) }
                } else {
                  ids.removeAll { $0 == source.id }
                }
                tier.conditions.indexerIds = ids.isEmpty ? nil : ids
              }))
        }
      }
      Section("Availability") {
        number("Minimum seeders", value: $tier.conditions.minSeeders, minimum: 0)
        TextField(
          "Maximum size in MB",
          text: Binding(
            get: { tier.conditions.maxSizeBytes.map { String(Double($0) / 1_000_000) } ?? "" },
            set: {
              let value = Double($0)
              tier.conditions.maxSizeBytes = value.flatMap {
                $0 > 0 && $0 < Double(Int.max) / 1_000_000 ? Int($0 * 1_000_000) : nil
              }
            })
        ).keyboardType(.decimalPad)
        Toggle(
          "Freeleech only",
          isOn: Binding(
            get: { tier.conditions.freeleechOnly ?? false },
            set: { tier.conditions.freeleechOnly = $0 }))
        Toggle(
          "Exclude VIP-only releases",
          isOn: Binding(
            get: { tier.conditions.excludeVipOnly ?? false },
            set: { tier.conditions.excludeVipOnly = $0 }))
      }
    }
    .navigationTitle("Release tier")
  }
  private func selection(_ values: Binding<[String]?>, _ value: String) -> Binding<Bool> {
    Binding(
      get: { values.wrappedValue?.contains(value) == true },
      set: { selected in
        var items = values.wrappedValue ?? []
        if selected {
          if !items.contains(value) { items.append(value) }
        } else {
          items.removeAll { $0 == value }
        }
        values.wrappedValue = items.isEmpty ? nil : items
      })
  }
  private func number(_ title: String, value: Binding<Double?>, minimum: Double) -> some View {
    TextField(
      title,
      text: Binding(
        get: { value.wrappedValue.map { String(Int($0)) } ?? "" },
        set: {
          let parsed = Double($0)
          value.wrappedValue = parsed.flatMap {
            $0 >= minimum && $0.rounded() == $0 && $0.isFinite ? $0 : nil
          }
        })
    ).keyboardType(.numberPad)
  }
}
