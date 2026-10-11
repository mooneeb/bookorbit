import SwiftUI

struct BulkActionsView: View {
  @State private var model: BulkActionsModel
  let user: AuthUser
  let completed: () -> Void
  @Environment(\.dismiss) private var dismiss
  @FocusState private var valueFocused: Bool

  init(api: BookOrbitAPI, user: AuthUser, bookIDs: [Int], completed: @escaping () -> Void) {
    _model = State(initialValue: BulkActionsModel(api: api, user: user, bookIDs: bookIDs))
    self.user = user
    self.completed = completed
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("Selected books") {
          Text("\(model.bookIDs.count) explicitly selected books")
            .accessibilityIdentifier("bulkSelectionCount")
          Text(
            "Books are edited in batches of 25. After an interruption, review current values before retrying."
          )
          if !model.availableActions.isEmpty {
            Picker("Action", selection: $model.action) {
              ForEach(model.availableActions, id: \.self) {
                Text($0.rawValue).tag($0)
              }
            }.accessibilityIdentifier("bulkAction").disabled(model.isBusy)
          }
        }
        if model.action == .edit && model.canEdit {
          Section("Edit") {
            Picker("Field", selection: $model.field) {
              ForEach(BulkActionsModel.Field.allCases, id: \.self) { Text($0.label).tag($0) }
            }.accessibilityIdentifier("bulkField")
            if model.field == .customMetadata {
              Picker("Custom field", selection: $model.customFieldID) {
                ForEach(model.customFields, id: \.id) { Text($0.label).tag(Optional($0.id)) }
              }.accessibilityIdentifier("bulkCustomField")
              Text(
                "Use true or false for boolean fields, or YYYY-MM-DD for dates. Fields must be enabled in each selected book's library."
              )
            }
            Toggle("Clear this field", isOn: $model.clearValue).accessibilityIdentifier(
              "bulkClearValue")
            if !model.clearValue {
              TextField(
                model.isArray ? "One value per line" : "Value", text: $model.value, axis: .vertical
              )
              .accessibilityIdentifier("bulkValue")
              .focused($valueFocused)
              if model.isArray {
                Picker("Relationship operation", selection: $model.arrayMode) {
                  Text("Add").tag("add")
                  Text("Remove").tag("remove")
                  Text("Replace").tag("replace")
                }.accessibilityIdentifier("bulkArrayMode")
              }
            }
          }.disabled(model.isBusy)
        } else if model.action == .content && model.canExport {
          Section("Content") {
            Toggle("All formats", isOn: $model.allFormats).accessibilityIdentifier("bulkAllFormats")
            Toggle("Audio only", isOn: $model.audioOnly).accessibilityIdentifier("bulkAudioOnly")
          }.disabled(model.isBusy)
        } else if model.canExport {
          Section("Metadata options") {
            Toggle("Include my reading data", isOn: $model.includePersonalData)
            Toggle("Include server file paths", isOn: $model.includeFilePaths)
          }.disabled(model.isBusy)
        }
        if !model.canEdit && !model.canExport {
          Text("Your account cannot edit metadata or export books.").accessibilityIdentifier(
            "bulkDenied")
        } else {
          Section {
            Button("Preview selected batch", action: prepare).disabled(!model.canPrepare)
              .accessibilityIdentifier("previewBulkActions")
          }
        }
        if let preview = model.preview {
          Section("Review selected changes") {
            Text("Field: \(model.field.label). Value: \(model.clearValue ? "Clear" : model.value)")
              .accessibilityIdentifier("bulkPreviewChange")
            ForEach(preview.fields.keys.sorted(), id: \.self) { key in
              if let field = preview.fields[key] {
                Text(
                  "\(BulkActionsModel.Field(rawValue: key)?.label ?? key): \(field.updated) eligible, \(field.skippedLocked) locked"
                )
              }
            }
            ForEach(preview.books, id: \.bookId) { book in
              VStack(alignment: .leading, spacing: 6) {
                Text("#\(book.bookId): \(book.title ?? "Untitled")")
                ForEach(book.currentValues, id: \.field) { value in
                  Text(
                    "Current \(BulkActionsModel.Field(rawValue: value.field)?.label ?? value.field): \(value.value ?? "Empty")"
                  ).font(.subheadline)
                }
              }
            }
          }.accessibilityIdentifier("bulkPreview")
        }
        if let summary = model.exportSummary {
          Section("Export preview") { Text(summary).accessibilityIdentifier("bulkExportPreview") }
        }
        if model.canApply {
          Button(
            model.action == .edit ? "Apply reviewed changes" : "Download export", action: apply
          )
          .accessibilityIdentifier("applyBulkActions")
        }
        if model.isBusy {
          Section {
            ProgressView(
              model.progress.map { "Received \($0.received) bytes" } ?? "Processing selected batch"
            )
            .accessibilityIdentifier("bulkProgress")
            Button("Cancel remaining work", action: model.cancel).accessibilityIdentifier(
              "cancelBulkActions")
          }
        }
        if let message = model.message { Text(message).accessibilityIdentifier("bulkStatus") }
        if let artifact = model.artifact {
          Section("Downloaded export") {
            Text("\(artifact.filename), \(artifact.size) bytes").accessibilityIdentifier(
              "bulkArtifact")
            Button("Save export to Files", action: model.save).accessibilityIdentifier(
              "saveBulkExport")
            Button("Share export", action: model.share).accessibilityIdentifier("shareBulkExport")
          }
        }
      }
      .disabled(model.delivery != nil)
      .navigationTitle("Bulk actions")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done", action: dismiss.callAsFunction).disabled(model.isBusy)
        }
      }
      .sheet(item: $model.delivery) {
        BookFileDeliveryView(presentation: $0, completed: model.delivered)
      }
      .interactiveDismissDisabled(model.isBusy)
      .task {
        model.configure(user: user)
        await model.load()
      }
      .onChange(of: user) { model.configure(user: user) }
      .onDisappear(perform: model.close)
      .onChange(of: model.action) { model.invalidatePreview() }
      .onChange(of: model.field) { model.invalidatePreview() }
      .onChange(of: model.value) { model.invalidatePreview() }
      .onChange(of: model.clearValue) { model.invalidatePreview() }
      .onChange(of: model.arrayMode) { model.invalidatePreview() }
      .onChange(of: model.customFieldID) { model.invalidatePreview() }
      .onChange(of: model.allFormats) { model.invalidatePreview() }
      .onChange(of: model.audioOnly) { model.invalidatePreview() }
      .onChange(of: model.includePersonalData) { model.invalidatePreview() }
      .onChange(of: model.includeFilePaths) { model.invalidatePreview() }
    }
  }

  private func prepare() {
    valueFocused = false
    model.prepare()
  }

  private func apply() {
    valueFocused = false
    model.apply(completed: completed)
  }
}
