import SwiftUI

struct EntityEditorView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var model: EntityEditModel
  @State private var choosingTarget = false

  init(api: BookOrbitAPI, kind: EntityKind, item: BrowseEntityItem) {
    _model = State(initialValue: EntityEditModel(api: api, kind: kind, item: item))
  }

  var body: some View {
    NavigationStack {
      Form {
        if let error = model.error {
          Section("Could not complete operation") {
            Text(error).foregroundStyle(.red)
            Button("Refresh preview") { Task { await model.load() } }
          }
        }
        if let outcome = model.outcome {
          Section("Completed") { Text(outcome).accessibilityIdentifier("entityOutcome") }
        }
        if let info = model.info {
          Section("Affected books") {
            Text("\(info.bookCount) books").accessibilityIdentifier("entityAffectedCount")
            ForEach(Array(info.bookTitles.enumerated()), id: \.offset) { _, title in Text(title) }
            Text("Books, files, notes and reading progress are retained.").font(.footnote)
          }
        }
        if !model.completed {
          Section("Rename") {
            TextField("Name", text: $model.name).accessibilityIdentifier("entityName")
            Button("Preview rename") { Task { await model.prepare(.rename(model.name)) } }
              .accessibilityIdentifier("entityPreviewRename")
          }
          Section("Merge") {
            Button("Choose merge target") { choosingTarget = true }
              .accessibilityIdentifier("entityChooseTarget")
          }
          if model.kind.canSplit {
            Section("Split relationships") {
              TextField("Names, one per line", text: $model.splitNames, axis: .vertical)
                .lineLimit(3...8)
                .accessibilityIdentifier("entitySplitNames")
              Button("Preview split") {
                let names = model.splitNames.components(separatedBy: .newlines)
                  .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                Task { await model.prepare(.split(names)) }
              }
              .accessibilityIdentifier("entityPreviewSplit")
            }
          }
          Section("Remove relationships") {
            if model.kind.canDetach {
              Button("Preview detach from books") { Task { await model.prepare(.remove("soft")) } }
                .accessibilityIdentifier("entityPreviewDetach")
            }
            Button("Preview delete entity", role: .destructive) {
              Task { await model.prepare(.remove(model.kind.isInline ? "inline" : "hard")) }
            }
            .accessibilityIdentifier("entityPreviewDelete")
          }
          Section("Server files") {
            Toggle("Write updated metadata to book files", isOn: $model.writeFiles)
            Text(
              "File writes run on the server. Check each book's file write status after completion."
            ).font(.footnote)
          }
        }
        if model.busy { ProgressView("Loading entity") }
      }
      .disabled(model.busy)
      .navigationTitle(model.item.name)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done", action: dismiss.callAsFunction)
        }
      }
      .task { await model.load() }
      .sheet(isPresented: $choosingTarget) {
        EntityTargetPickerView(api: model.api, kind: model.kind, source: model.item.id) { target in
          choosingTarget = false
          Task { await model.prepare(.merge(target)) }
        }
      }
      .alert(
        "Review entity change",
        isPresented: Binding(
          get: { model.preview != nil }, set: { if !$0 { model.preview = nil } }
        )
      ) {
        Button("Apply", role: .destructive) { Task { await model.apply() } }
          .accessibilityIdentifier("entityApply")
        Button("Cancel", role: .cancel) { model.cancelPreview() }
      } message: {
        Text(model.preview ?? "")
      }
    }
  }
}

private struct EntityTargetPickerView: View {
  let source: StringOrNumber
  let choose: (BrowseEntityItem) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var model: EntityDirectoryModel

  init(
    api: BookOrbitAPI, kind: EntityKind, source: StringOrNumber,
    choose: @escaping (BrowseEntityItem) -> Void
  ) {
    self.source = source
    self.choose = choose
    _model = State(initialValue: EntityDirectoryModel(api: api, kind: kind))
  }

  var body: some View {
    NavigationStack {
      VStack {
        OrganizationSearchField(text: $model.search, prompt: "Search merge targets") {
          Task { await model.load() }
        }
        .padding(.horizontal)
        if let error = model.error {
          Text(error).foregroundStyle(.red)
          Button("Retry") { Task { await model.load(page: model.page) } }
        }
        List(model.items.filter { $0.id != source }) { item in
          Button {
            choose(item)
          } label: {
            VStack(alignment: .leading) {
              Text(item.name)
              Text("\(item.bookCount) books").font(.footnote)
            }
          }
          .accessibilityIdentifier("entityTarget\(item.id.entityPath)")
        }
        if model.busy { ProgressView() }
        HStack {
          Button("Previous") { Task { await model.load(page: model.page - 1) } }
            .disabled(model.page <= 1 || model.busy)
          Spacer()
          Text("Page \(model.page), \(model.total) results").font(.footnote)
          Spacer()
          Button("Next") { Task { await model.load(page: model.page + 1) } }
            .disabled(model.page * 40 >= model.total || model.busy)
        }.padding()
      }
      .navigationTitle("Choose merge target")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel", action: dismiss.callAsFunction)
        }
      }
      .task { await model.load() }
    }
  }
}
