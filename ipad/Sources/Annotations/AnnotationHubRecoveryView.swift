import SwiftUI

struct AnnotationHubRecoveryView: View {
  @Bindable var model: AnnotationHubModel
  let repository: NativeAnnotationRepository
  let canEditPdfInk: Bool
  @State private var storage = "device"
  @State private var drafts: [NativeAnnotationRecoveryDraft] = []
  @State private var cursor: Int?
  @State private var nextCursor: Int?
  @State private var previousCursors: [Int?] = []
  @State private var error: String?
  @State private var isBusy = false
  @State private var exportedDraft: AnnotationHubExportDocument?
  @State private var showingExporter = false
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        Section {
          Picker("Saved on", selection: $storage) {
            Text("This iPad").tag("device")
            Text("Server").tag("server")
          }.pickerStyle(.segmented).disabled(isBusy)
            .accessibilityIdentifier("annotationHubRecoveryStorage")
        }
        Section {
          Text(
            "Recovery drafts preserve changes that could not replace the current annotation. A deleted annotation stays deleted until you explicitly restore it."
          )
          .fixedSize(horizontal: false, vertical: true)
          Text(
            "Export a draft to keep its text, original drawing and operation details. Attach as new annotation asks you to choose an edition and confirm its passage. The original stays unchanged and the draft is retained."
          )
          .fixedSize(horizontal: false, vertical: true)
        }
        if isBusy { Section { ProgressView("Loading recovery drafts…") } }
        if let error {
          Section("Recovery status") {
            Text(error).accessibilityIdentifier("annotationHubRecoveryError")
            Button("Try again", action: reload)
          }
        }
        ForEach(drafts) { draft in
          Section("Book \(draft.bookId)") {
            Text(reason(draft.reason)).font(.headline)
            if let text = draft.item?.text ?? draft.operation.payload?.text, !text.isEmpty {
              Text(text).textSelection(.enabled)
            }
            if let note = draft.item?.note ?? draft.operation.payload?.note, !note.isEmpty {
              Text(note).textSelection(.enabled)
            }
            if draft.operation.payload?.drawing != nil || draft.item?.drawing != nil {
              Label("Original drawing retained", systemImage: "pencil.tip")
            }
            Button("Export recovery draft") { export(draft) }.frame(minHeight: 44)
              .accessibilityIdentifier("annotationHubExportDraft\(draft.id)")
            if let item = draft.item, canEditPdfInk || item.kind != "pdf_ink" {
              Button("Attach as new annotation") { reattach(draft) }.frame(minHeight: 44)
                .accessibilityIdentifier("annotationHubReattachDraft\(draft.id)")
            } else if draft.item == nil {
              Text(
                "The original annotation details are unavailable. Export this draft to preserve its saved operation for manual recovery."
              )
              .accessibilityIdentifier("annotationHubRecoverySnapshotUnavailable\(draft.id)")
            }
          }.accessibilityElement(children: .contain)
            .accessibilityIdentifier("annotationHubRecoveryDraft\(draft.id)")
        }
        if !isBusy, drafts.isEmpty, error == nil { Text("No recovery drafts are saved.") }
        Section {
          Button("Previous", action: previous).disabled(previousCursors.isEmpty || isBusy)
          Button("Next", action: next).disabled(nextCursor == nil || isBusy)
        }
      }.font(.body).buttonStyle(.plain).foregroundStyle(Color(uiColor: .label))
        .navigationTitle("Recovery drafts")
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Done", action: dismiss.callAsFunction)
          }
        }
        .task { await load() }
        .onChange(of: storage, reset)
        .fileExporter(
          isPresented: $showingExporter, document: exportedDraft, contentTypes: [.json],
          defaultFilename: "BookOrbit recovery draft", onCompletion: exported
        )
        .sheet(item: $model.repairBook) { book in
          AnnotationHubRepairView(
            book: book, format: model.repairFormat, choose: model.chooseRepairFile)
        }
        .fullScreenCover(item: $model.reader) { destination in
          AnnotationHubReaderView(model: model, destination: destination)
        }
    }
  }

  private func reason(_ reason: String) -> String {
    switch reason {
    case "deleted", "annotation_deleted":
      String(localized: "The annotation was deleted in another reader")
    case "source_replaced": String(localized: "The source file was replaced")
    case "source_deleted": String(localized: "The source file was deleted")
    case "version_conflict", "concurrent_edit":
      String(localized: "Another reader saved a newer version")
    default: String(localized: "This saved change needs review")
    }
  }

  private func reload() { Task { await load() } }
  private func reset() {
    cursor = nil
    nextCursor = nil
    previousCursors = []
    drafts = []
    Task { await load() }
  }
  private func next() {
    guard let nextCursor else { return }
    previousCursors.append(cursor)
    cursor = nextCursor
    Task { await load() }
  }
  private func previous() {
    guard !previousCursors.isEmpty else { return }
    cursor = previousCursors.removeLast()
    Task { await load() }
  }

  private func load() async {
    guard !isBusy else { return }
    isBusy = true
    error = nil
    defer { isBusy = false }
    do {
      if storage == "device" {
        let page = try await repository.recoveryDraftsPage(cursor: cursor, limit: 40)
        drafts = page.items
        nextCursor = page.nextCursor
        return
      }
      var query = [URLQueryItem(name: "limit", value: "40")]
      if let cursor { query.append(.init(name: "cursor", value: String(cursor))) }
      let response: NativeAnnotationDraftResponse = try await model.api.boundedJSON(
        "annotations/native/hub/drafts", query: query, byteLimit: 32 * 1024 * 1024)
      guard response.items.count <= 40 else { throw ConnectionError.invalidResponse }
      drafts = response.items.map {
        NativeAnnotationRecoveryDraft(
          id: "server-\($0.id)", bookId: $0.bookId,
          item: $0.snapshot, operation: $0.payload, reason: $0.reason, createdAt: $0.createdAt,
          snapshotUnavailableReason: $0.snapshotUnavailableReason)
      }
      nextCursor = response.nextCursor
    } catch {
      self.error = error.localizedDescription
      drafts = []
      nextCursor = nil
    }
  }

  private func reattach(_ draft: NativeAnnotationRecoveryDraft) {
    Task { await model.beginDraftRepair(draft) }
  }

  private func export(_ draft: NativeAnnotationRecoveryDraft) {
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let data = try encoder.encode(draft)
      guard data.count <= AnnotationHubExportDocument.byteLimit else {
        throw AnnotationHubError(
          message: String(localized: "This recovery draft is too large to export."))
      }
      exportedDraft = .init(data: data)
      showingExporter = true
    } catch { self.error = error.localizedDescription }
  }

  private func exported(_ result: Result<URL, any Error>) {
    if case .failure(let error) = result { self.error = error.localizedDescription }
    exportedDraft = nil
  }
}
