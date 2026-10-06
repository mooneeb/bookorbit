import SwiftUI

struct SavedViewsView: View {
  let model: SavedViewModel
  let library: LibraryModel
  @Binding var presentation: String
  @Binding var layout: TableLayoutState
  @Environment(\.dismiss) private var dismiss
  @State private var name = ""
  @State private var renaming: NativeSavedView?
  @State private var deleting: NativeSavedView?
  @State private var rename = ""
  @State private var error: String?
  @State private var isApplying = false

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        List {
          Section("Save current view") {
            TextField("View name", text: $name).accessibilityIdentifier("savedViewName")
            Button("Save current view") {
              perform {
                try model.save(
                  name: name, library: library, presentation: presentation, layout: layout)
                name = ""
              }
            }
            .font(.body).frame(minHeight: 44).disabled(
              name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
            .accessibilityIdentifier("saveCurrentView")
            Text("Saved views stay on this iPad for this server and account.").font(.body)
          }
          Section("Saved views") {
            ForEach(model.views(at: library.location.storageKey)) { view in
              VStack(alignment: .leading, spacing: 10) {
                Button {
                  Task { await apply(view) }
                } label: {
                  Label(
                    view.view.name,
                    systemImage: view.view.favorite == true ? "star.fill" : "rectangle.grid.1x2"
                  )
                  .font(.headline).frame(maxWidth: .infinity, alignment: .leading)
                  .contentShape(Rectangle())
                }.buttonStyle(.plain).frame(minHeight: 44)
                  .accessibilityIdentifier("savedView\(view.id)")
                ViewThatFits(in: .horizontal) {
                  HStack { managementActions(view) }
                  VStack(alignment: .leading) { managementActions(view) }
                }.font(.body)
              }.padding(.vertical, 6)
            }
            if model.views(at: library.location.storageKey).isEmpty {
              Text("No saved views for this library location.").font(.body)
            }
          }
          if let error { Text(error).font(.body) }
          if isApplying { ProgressView("Applying view…") }
        }.buttonStyle(.plain).foregroundStyle(Color(uiColor: .label)).disabled(isApplying)
        Button("Done", action: dismiss.callAsFunction).font(.body).buttonStyle(.plain)
          .foregroundStyle(Color(uiColor: .label)).frame(minHeight: 44).padding()
          .disabled(isApplying)
      }.navigationTitle("Saved views")
        .interactiveDismissDisabled(isApplying)
        .alert(
          "Rename view",
          isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
        ) {
          TextField("View name", text: $rename)
          Button("Cancel", role: .cancel) { renaming = nil }
          Button("Rename") {
            if let renaming { perform { try model.rename(renaming, name: rename) } }
            renaming = nil
          }
        }
        .alert(
          "Delete saved view?",
          isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
        ) {
          Button("Cancel", role: .cancel) { deleting = nil }
          Button("Delete", role: .destructive) {
            if let deleting { perform { try model.remove(deleting) } }
            deleting = nil
          }
        } message: {
          Text("The books and shared smart scopes will remain.")
        }
    }
  }

  @ViewBuilder private func managementActions(_ view: NativeSavedView) -> some View {
    Button(view.view.favorite == true ? "Unfavorite" : "Favorite") {
      perform { try model.toggleFavorite(view) }
    }.frame(minHeight: 44)
    Button("Rename") {
      renaming = view
      rename = view.view.name
    }.frame(minHeight: 44)
    Button("Duplicate") { perform { try model.duplicate(view) } }.frame(minHeight: 44)
    Button("Delete", role: .destructive) { deleting = view }.frame(minHeight: 44)
  }

  private func perform(_ action: () throws -> Void) {
    error = nil
    do { try action() } catch { self.error = error.localizedDescription }
  }

  private func apply(_ view: NativeSavedView) async {
    guard !isApplying else { return }
    isApplying = true
    error = nil
    defer { isApplying = false }
    library.search = view.search
    await library.apply(filter: view.view.filter, sort: view.view.sort)
    if let failure = library.error {
      error = failure
      return
    }
    layout = BookTableLayout.normalized(view.view.layout)
    presentation = view.presentation
    dismiss()
  }
}
