import SwiftUI

struct AnnotationHubView: View {
  @State private var model: AnnotationHubModel
  let canRead: Bool
  let canManage: Bool
  let canEditPdfInk: Bool
  @State private var showingFilters = false
  @State private var showingDevices = false
  @State private var showingRecovery = false
  @State private var confirmingTrash = false
  @State private var exportDocument: AnnotationHubExportDocument?
  @State private var showingExporter = false
  @Environment(\.dismiss) private var dismiss

  init(api: BookOrbitAPI, userID: Int, canRead: Bool, canManage: Bool, canEditPdfInk: Bool) {
    _model = State(initialValue: AnnotationHubModel(api: api, userID: userID))
    self.canRead = canRead
    self.canManage = canManage
    self.canEditPdfInk = canEditPdfInk
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        OrganizationSearchField(
          text: $model.search, prompt: String(localized: "Search converted text and passages"),
          submit: search, identifier: "annotationHubSearch"
        )
        .padding()
        if let bookID = model.bookID {
          HStack {
            Text(model.bookTitle ?? String(localized: "Selected book"))
            Spacer()
            Button("All books", action: clearBook).frame(minHeight: 44)
          }.padding(.horizontal).accessibilityIdentifier("annotationHubBookFilter\(bookID)")
        }
        List {
          if let error = model.error {
            Section("Could not complete this action") {
              Text(error).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("annotationHubError")
              Button("Try again", action: reload).frame(minHeight: 44)
            }
          }
          if let notice = model.notice {
            Section { Text(notice).accessibilityIdentifier("annotationHubNotice") }
          }
          if let repository = model.repository, repository.pendingCount > 0 {
            Section {
              Text("\(repository.pendingCount) changes pending on this iPad")
                .accessibilityIdentifier("annotationHubPending")
            }
          }
          if model.isBusy {
            Section { ProgressView("Loading annotations…") }
          } else if model.items.isEmpty && model.error == nil {
            Section {
              Text("No annotations match these filters.")
                .accessibilityIdentifier("annotationHubEmpty")
              Text(
                "Search finds passages and converted text. Handwriting stays available in each note."
              )
              .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
          }
          ForEach(model.groups) { group in
            Section(group.title) {
              ForEach(group.items) { item in
                AnnotationHubRow(
                  item: item, selected: model.selected.contains(item.id),
                  toggle: { model.toggleSelection(item) }, open: { model.detail = item })
              }
            }
          }
        }
        .font(.body)
        .buttonStyle(.plain)
        .foregroundStyle(Color(uiColor: .label))
        controls
        HStack {
          Button("Previous", action: previous).disabled(model.isBusy || !model.canGoBack)
          Spacer()
          Text("Page \(model.page)").accessibilityIdentifier("annotationHubPage")
          Spacer()
          Button("Next", action: next).disabled(model.isBusy || model.nextCursor == nil)
        }.padding().font(.body).buttonStyle(.plain).foregroundStyle(Color(uiColor: .label))
      }
      .navigationTitle("Annotations")
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("Done", action: dismiss.callAsFunction).accessibilityIdentifier(
            "annotationHubDone")
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
          Button("Filters", action: openFilters).accessibilityIdentifier("annotationHubFilters")
          if canManage {
            Button("Devices", action: openDevices).accessibilityIdentifier("annotationHubDevices")
          }
        }
      }
      .task { await model.load() }
      .sheet(isPresented: $showingFilters) {
        AnnotationHubFiltersView(model: model)
      }
      .sheet(isPresented: $showingDevices) { AnnotationHubDevicesView(api: model.api) }
      .sheet(isPresented: $showingRecovery) {
        if let repository = model.repository {
          AnnotationHubRecoveryView(
            model: model, repository: repository, canEditPdfInk: canEditPdfInk)
        }
      }
      .sheet(item: $model.detail) { item in
        AnnotationHubDetailView(
          model: model, item: item, canRead: canRead,
          canManage: canManage, canEditPdfInk: canEditPdfInk)
      }
      .onChange(of: model.repository?.generation) {
        if !model.isBusy { Task { await model.load() } }
      }
      .confirmationDialog("Move selected annotations to Trash?", isPresented: $confirmingTrash) {
        Button("Move to Trash", role: .destructive, action: trash)
      } message: {
        Text(
          "The deletion is saved on this iPad and sent to other readers during synchronization. Undo remains available."
        )
      }
      .fileExporter(
        isPresented: $showingExporter, document: exportDocument, contentTypes: [.json],
        defaultFilename: "BookOrbit annotations", onCompletion: exported)
    }
  }

  private var controls: some View {
    ScrollView(.horizontal) {
      HStack(spacing: 20) {
        Text("\(model.selected.count) selected").accessibilityIdentifier(
          "annotationHubSelectedCount")
        Button("Select page", action: selectPage).disabled(model.items.isEmpty)
          .accessibilityIdentifier("annotationHubSelectPage")
        Button("Clear selection", action: clearSelection).disabled(model.selected.isEmpty)
        if canManage {
          Button("Export", action: prepareExport).disabled(model.selected.isEmpty)
            .accessibilityIdentifier("annotationHubExport")
          Button("Recovery drafts", action: openRecovery)
            .accessibilityIdentifier("annotationHubRecovery")
          if model.status == "trashed" {
            Button("Restore", action: restore).disabled(!canChangeSelection)
              .accessibilityIdentifier("annotationHubRestoreSelected")
          } else if model.status == "active" {
            Button("Trash", role: .destructive, action: promptTrash).disabled(!canChangeSelection)
              .accessibilityIdentifier("annotationHubTrashSelected")
          }
          Button("Undo", action: undo).disabled(!model.canUndo)
            .accessibilityIdentifier("annotationHubUndo")
        }
        Button("Synchronize", action: synchronize).accessibilityIdentifier(
          "annotationHubSynchronize")
      }.frame(minHeight: 44).padding(.horizontal)
    }.font(.body).buttonStyle(.plain).foregroundStyle(Color(uiColor: .label))
      .disabled(model.isBusy)
  }

  private func openFilters() { showingFilters = true }
  private func openDevices() { showingDevices = true }
  private func openRecovery() { showingRecovery = true }
  private var canChangeSelection: Bool {
    !model.selected.isEmpty
      && (canEditPdfInk || !model.selectedItems.contains { $0.kind == "pdf_ink" })
  }
  private func selectPage() { model.selected = Set(model.items.map(\.id)) }
  private func clearSelection() { model.selected = [] }
  private func promptTrash() { confirmingTrash = true }
  private func search() { Task { await model.load(reset: true) } }
  private func reload() { Task { await model.load() } }
  private func clearBook() { Task { await model.clearBook() } }
  private func next() { Task { await model.next() } }
  private func previous() { Task { await model.previous() } }
  private func trash() { Task { await model.mutateSelection(action: "delete") } }
  private func restore() { Task { await model.mutateSelection(action: "restore") } }
  private func undo() { Task { await model.undo() } }
  private func synchronize() { Task { await model.synchronize() } }

  private func prepareExport() {
    do {
      exportDocument = try model.exportSelection()
      showingExporter = true
    } catch { model.error = error.localizedDescription }
  }

  private func exported(_ result: Result<URL, any Error>) {
    switch result {
    case .success:
      model.notice = String(
        localized: "Annotations exported with retained drawings and version details.")
    case .failure(let error): model.error = error.localizedDescription
    }
    exportDocument = nil
  }
}

private struct AnnotationHubRow: View {
  let item: NativeAnnotationHubItem
  let selected: Bool
  let toggle: () -> Void
  let open: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Button(action: toggle) {
        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
          .font(.title2).frame(minWidth: 44, minHeight: 44)
      }
      .accessibilityLabel(
        selected ? String(localized: "Deselect annotation") : String(localized: "Select annotation")
      )
      .accessibilityIdentifier("annotationHubSelect\(item.id)")
      Button(action: open) {
        VStack(alignment: .leading, spacing: 6) {
          Text(item.bookTitle ?? String(localized: "Untitled book")).font(.headline)
          Text(AnnotationHubLabels.kind(item.kind)).font(.subheadline)
          if !item.text.isEmpty { Text(item.text).lineLimit(3) }
          if let note = item.note, !note.isEmpty { Text(note).lineLimit(3) }
          if item.drawing != nil {
            Label("Retained handwriting", systemImage: "pencil.tip").font(.subheadline)
          }
          if ["failed", "pending"].contains(item.positionStatus ?? "") {
            Label("Passage needs repair", systemImage: "exclamationmark.triangle").font(
              .subheadline)
          }
          Text(
            [item.fileFormat?.uppercased(), AnnotationHubLabels.source(item.origin)].compactMap {
              $0
            }.joined(separator: " · ")
          )
          .font(.subheadline).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
          .contentShape(Rectangle())
      }.accessibilityIdentifier("annotationHubItem\(item.id)")
    }
  }
}

private struct AnnotationHubFiltersView: View {
  let model: AnnotationHubModel
  @State private var kind: String
  @State private var status: String
  @State private var groupBy: String
  @Environment(\.dismiss) private var dismiss

  init(model: AnnotationHubModel) {
    self.model = model
    _kind = State(initialValue: model.kind)
    _status = State(initialValue: model.status)
    _groupBy = State(initialValue: model.groupBy)
  }

  var body: some View {
    NavigationStack {
      Form {
        Picker("Type", selection: $kind) {
          Text("All types").tag("")
          Text("Highlights").tag("highlight")
          Text("Text notes").tag("text_note")
          Text("Handwritten notes").tag("handwriting")
          Text("PDF ink").tag("pdf_ink")
        }.accessibilityIdentifier("annotationHubKind")
        Picker("Location", selection: $status) {
          Text("Annotations").tag("active")
          Text("Trash").tag("trashed")
          Text("Recovery").tag("recovery")
        }.accessibilityIdentifier("annotationHubStatus")
        Picker("Group by", selection: $groupBy) {
          Text("Book").tag("book")
          Text("Month").tag("month")
          Text("Type").tag("kind")
          Text("Source").tag("source")
        }.accessibilityIdentifier("annotationHubGrouping")
        Text(
          "Search matches converted text, notes, passages and book titles. Raw handwriting is preserved in exports."
        )
        .fixedSize(horizontal: false, vertical: true)
      }
      .navigationTitle("Annotation filters")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel", action: dismiss.callAsFunction)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Apply", action: apply).accessibilityIdentifier("annotationHubApplyFilters")
        }
      }
    }
  }

  private func apply() {
    model.kind = kind
    model.status = status
    model.groupBy = groupBy
    dismiss()
    Task { await model.load(reset: true) }
  }
}
