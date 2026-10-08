import SwiftUI

struct TablePresetsView: View {
  let model: TablePresetModel
  let library: LibraryModel
  @Binding var layout: TableLayoutState
  @Environment(\.dismiss) private var dismiss
  @State private var name = ""
  @State private var includeSort = true
  @State private var renaming: TablePreset?
  @State private var deleting: TablePreset?
  @State private var renamedName = ""
  @State private var error: String?
  @State private var isApplying = false

  private var location: String { library.location.storageKey }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        List {
          Section("Save column preset") {
            TextField("Preset name", text: $name).accessibilityIdentifier("tablePresetName")
            Toggle("Include current sort", isOn: $includeSort)
              .accessibilityIdentifier("tablePresetIncludeSort")
            Button("Save column preset", action: save)
              .frame(minHeight: 44)
              .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
              .accessibilityIdentifier("saveTablePreset")
            Text(
              "Presets save column layouts and optional sort. Your filters and search stay active."
            )
            .font(.body).fixedSize(horizontal: false, vertical: true)
            Text("Custom presets stay on this iPad for this server, account, and library location.")
              .font(.body).fixedSize(horizontal: false, vertical: true)
          }
          Section("Column presets") {
            ForEach(model.presets(at: location)) { preset in
              VStack(alignment: .leading, spacing: 10) {
                Button {
                  Task { await apply(preset) }
                } label: {
                  Label(
                    preset.name,
                    systemImage: preset.favorite == true ? "star.fill" : "tablecells"
                  )
                  .font(.headline)
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .contentShape(Rectangle())
                }.frame(minHeight: 44)
                  .accessibilityIdentifier("tablePreset\(preset.id)")
                if preset.isBuiltIn == true {
                  Text("Built-in").font(.body)
                } else {
                  ViewThatFits(in: .horizontal) {
                    HStack { actions(preset) }
                    VStack(alignment: .leading) { actions(preset) }
                  }
                }
                if !BookTableLayout.unavailable(
                  preset.layout, customFields: library.tableCustomFields
                ).isEmpty {
                  Text(
                    "Some columns in this preset are unavailable on this iPad. Their settings are preserved."
                  )
                  .font(.body).fixedSize(horizontal: false, vertical: true)
                }
              }.padding(.vertical, 6)
            }
          }
          if let error { Text(error).font(.body).fixedSize(horizontal: false, vertical: true) }
          if isApplying { ProgressView("Applying preset…") }
        }.font(.body).buttonStyle(.plain).foregroundStyle(Color(uiColor: .label))
          .disabled(isApplying)
        Button("Done", action: dismiss.callAsFunction)
          .font(.body).buttonStyle(.plain).foregroundStyle(Color(uiColor: .label))
          .frame(minHeight: 44).padding().disabled(isApplying)
      }.navigationTitle("Column presets")
        .interactiveDismissDisabled(isApplying)
        .alert(
          "Rename preset",
          isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
        ) {
          TextField("Preset name", text: $renamedName)
          Button("Cancel", role: .cancel) { renaming = nil }
          Button("Rename") {
            if let renaming {
              perform { try model.rename(renaming.id, name: renamedName, at: location) }
            }
            renaming = nil
          }
        }
        .alert(
          "Delete column preset?",
          isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
        ) {
          Button("Cancel", role: .cancel) { deleting = nil }
          Button("Delete", role: .destructive) {
            if let deleting { perform { try model.remove(deleting.id, at: location) } }
            deleting = nil
          }
        } message: {
          Text("This removes the local preset. Your books and saved views remain available.")
        }
    }
  }

  @ViewBuilder private func actions(_ preset: TablePreset) -> some View {
    Button(preset.favorite == true ? "Unfavorite" : "Favorite") {
      perform { try model.toggleFavorite(preset.id, at: location) }
    }.frame(minHeight: 44).accessibilityIdentifier("favoriteTablePreset\(preset.id)")
    Button("Rename") {
      renaming = preset
      renamedName = preset.name
    }.frame(minHeight: 44).accessibilityIdentifier("renameTablePreset\(preset.id)")
    Button("Duplicate") { perform { try model.duplicate(preset.id, at: location) } }
      .frame(minHeight: 44).accessibilityIdentifier("duplicateTablePreset\(preset.id)")
    Button("Delete", role: .destructive) { deleting = preset }
      .frame(minHeight: 44).accessibilityIdentifier("deleteTablePreset\(preset.id)")
  }

  private func save() {
    perform {
      let sort =
        includeSort
        ? [SortSpec(field: library.sort, dir: library.descending ? "desc" : "asc")]
          + library.secondarySort : nil
      try model.save(name: name, layout: layout, sort: sort, at: location)
      name = ""
    }
  }

  private func perform(_ action: () throws -> Void) {
    error = nil
    do { try action() } catch { self.error = error.localizedDescription }
  }

  private func apply(_ preset: TablePreset) async {
    guard !isApplying else { return }
    isApplying = true
    error = nil
    defer { isApplying = false }
    do {
      try await library.applyPresetSort(preset.sort)
      if let failure = library.error, preset.sort?.isEmpty == false {
        error = failure
        return
      }
      layout = BookTableLayout.normalized(preset.layout)
      dismiss()
    } catch { self.error = error.localizedDescription }
  }
}
