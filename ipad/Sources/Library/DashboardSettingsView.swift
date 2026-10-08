import SwiftUI

struct DashboardSettingsView: View {
  @Bindable var model: DashboardModel
  @Environment(\.dismiss) private var dismiss
  @State private var shelves: [ScrollerConfig]
  @State private var layout: String
  @State private var sync: Bool
  @State private var showingScopeSelection = false

  init(model: DashboardModel) {
    self.model = model
    _shelves = State(initialValue: model.configuration.scrollers ?? [])
    _layout = State(initialValue: model.configuration.shelfLayout ?? "wide")
    _sync = State(initialValue: model.configuration.syncAcrossSessions ?? false)
  }

  var body: some View {
    NavigationStack {
      List {
        Section("Layout") {
          Picker("Shelf layout", selection: $layout) {
            Text("Wide").tag("wide")
            Text("Two columns").tag("two-columns")
          }
          Toggle("Sync shelves with web", isOn: $sync).disabled(!model.canSync)
        }
        Section("Shelves") {
          ForEach($shelves) { $shelf in
            VStack(alignment: .leading, spacing: 12) {
              TextField("Shelf name", text: $shelf.label)
              Toggle("Enabled", isOn: $shelf.enabled)
              Text(DashboardShelfType(rawValue: shelf.type)?.title ?? "Podcast shelf")
                .font(.body)
                .foregroundStyle(Color(uiColor: .label))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .accessibilityElement(children: .combine)
              Stepper(
                "Books per row: \(Int(shelf.limit))", value: $shelf.limit, in: 1...50, step: 1)
              Stepper("Rows: \(Int(shelf.rows))", value: $shelf.rows, in: 1...3, step: 1)
            }.padding(.vertical, 8)
          }
          .onMove(perform: move)
          .onDelete(perform: remove)
          Menu("Add shelf") {
            ForEach(DashboardShelfType.allCases.filter { $0 != .smartScope }) { type in
              Button(type.title) { add(type) }
            }
            Button("Smart scope") { showingScopeSelection = true }
          }.disabled(shelves.count >= 8)
        }
        if let error = model.settingsError {
          Section { Text(error).foregroundStyle(Color(uiColor: .label)) }
        }
        if model.isSaving { ProgressView("Saving shelves…") }
      }
      .disabled(model.isSaving)
      .safeAreaInset(edge: .bottom) {
        HStack {
          Button(action: dismiss.callAsFunction) {
            Text("Cancel")
              .font(.body)
              .padding(.horizontal, 16)
              .frame(minWidth: 44, minHeight: 44)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .foregroundStyle(Color(uiColor: .label))
          .disabled(model.isSaving)
          Spacer()
        }
        .padding(.horizontal)
        .background(Color(uiColor: .systemBackground))
      }
      .navigationTitle("Dashboard shelves")
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) { EditButton().disabled(model.isSaving) }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save", action: save).disabled(model.isSaving)
        }
      }
      .interactiveDismissDisabled(model.isSaving)
      .sheet(isPresented: $showingScopeSelection) {
        SmartScopePicker(api: model.api) { scope in
          guard shelves.count < 8 else { return }
          shelves.append(
            ScrollerConfig(
              id: UUID().uuidString, type: DashboardShelfType.smartScope.rawValue,
              label: scope.name, enabled: true, order: Double(shelves.count + 1), limit: 20,
              rows: 1, smartScopeId: scope.id))
        }
      }
    }
  }

  private func add(_ type: DashboardShelfType) {
    guard shelves.count < 8 else { return }
    shelves.append(
      ScrollerConfig(
        id: UUID().uuidString, type: type.rawValue, label: type.title,
        enabled: true, order: Double(shelves.count + 1), limit: 20, rows: 1, smartScopeId: nil))
  }

  private func move(from: IndexSet, to: Int) { shelves.move(fromOffsets: from, toOffset: to) }
  private func remove(_ offsets: IndexSet) { shelves.remove(atOffsets: offsets) }
  private func save() {
    let configuration = DashboardShelfConfig(
      syncAcrossSessions: sync, scrollers: shelves, shelfLayout: layout)
    Task { if await model.save(configuration) { dismiss() } }
  }
}
