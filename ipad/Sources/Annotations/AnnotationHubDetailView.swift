import PencilKit
import SwiftUI

struct AnnotationHubDetailView: View {
  @Bindable var model: AnnotationHubModel
  let item: NativeAnnotationHubItem
  let canRead: Bool
  let canManage: Bool
  let canEditPdfInk: Bool
  @State private var exportDocument: AnnotationHubExportDocument?
  @State private var showingExporter = false
  @State private var showingSourceRecovery = false
  @Environment(\.dismiss) private var dismiss

  private var canChange: Bool {
    canManage && (item.kind != "pdf_ink" || canEditPdfInk) && model.status != "recovery"
  }

  var body: some View {
    NavigationStack {
      List {
        Section {
          Text(item.bookTitle ?? String(localized: "Untitled book")).font(.title2)
          Text(AnnotationHubLabels.kind(item.kind)).font(.headline)
          if let author = item.author { Text(author) }
          if !item.text.isEmpty { Text(item.text).textSelection(.enabled) }
          if let note = item.note { Text(note).textSelection(.enabled) }
          if let drawing = item.drawing { AnnotationHubDrawingView(drawing: drawing) }
        }
        Section("Passage") {
          if let title = item.chapterTitle { Text(title) }
          if let page = item.pdf?.page {
            Text("Page \(page + 1)")
          } else if let page = item.pageno {
            Text("Page \(page)")
          }
          Text(
            item.positionStatus == "exact" || item.positionStatus == "repaired"
              ? String(localized: "Passage is available")
              : String(localized: "Passage needs review"))
          if canRead, item.deletedAt == nil, model.status != "recovery" {
            Button("Open passage", action: open).frame(minHeight: 44)
              .accessibilityIdentifier("annotationHubOpenPassage")
          }
          if canChange, item.deletedAt == nil {
            Button("Repair passage", action: repair).frame(minHeight: 44)
              .accessibilityIdentifier("annotationHubRepair")
          }
          Button("Show this book's annotations", action: showBook).frame(minHeight: 44)
        }
        Section("Synchronization") {
          Text("Version \(item.version.formatted())")
          Text(AnnotationHubLabels.source(item.origin))
          if let format = item.fileFormat { Text(format.uppercased()) }
          if let date = AnnotationHubLabels.date(item.updatedAt ?? item.createdAt) {
            Text(date, format: .dateTime.year().month().day().hour().minute())
          }
          if item.deletedAt != nil { Text("In Trash") }
          if model.status == "recovery" {
            Text(
              "This saved version needs review. Export it before choosing an explicit reattachment."
            )
            .fixedSize(horizontal: false, vertical: true)
          }
          if canManage, item.jumpFileId != nil {
            Button("Retained source versions", action: openSourceRecovery).frame(minHeight: 44)
              .accessibilityIdentifier("sourceRecoveryOpen")
          }
        }
        Section {
          if canManage {
            Button("Export annotation", action: exportAnnotation).frame(minHeight: 44)
              .accessibilityIdentifier("annotationHubExportDetail")
          }
          if canChange {
            if item.deletedAt == nil {
              Button("Move to Trash", role: .destructive, action: trash).frame(minHeight: 44)
                .accessibilityIdentifier("annotationHubTrashDetail")
            } else {
              Button("Restore annotation", action: restore).frame(minHeight: 44)
                .accessibilityIdentifier("annotationHubRestoreDetail")
            }
          }
        }
        if let error = model.error {
          Section("Could not complete this action") {
            Text(error).accessibilityIdentifier("annotationHubDetailError")
          }
        }
      }
      .font(.body).buttonStyle(.plain).foregroundStyle(Color(uiColor: .label))
      .navigationTitle("Annotation")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done", action: dismiss.callAsFunction)
        }
      }
      .disabled(model.isBusy)
      .sheet(item: $model.repairBook) { book in
        AnnotationHubRepairView(
          book: book, format: model.repairFormat, choose: model.chooseRepairFile)
      }
      .fullScreenCover(item: $model.reader, onDismiss: reload) { destination in
        AnnotationHubReaderView(model: model, destination: destination)
      }
      .fileExporter(
        isPresented: $showingExporter, document: exportDocument,
        contentTypes: [.json], defaultFilename: "BookOrbit annotation", onCompletion: exported
      )
      .sheet(isPresented: $showingSourceRecovery) {
        SourceRecoveryView(
          api: model.api, bookID: item.bookId, fileID: item.jumpFileId,
          reattachDraft: reattachSourceDraft)
      }
    }
  }

  private func open() { Task { await model.openPassage(item) } }
  private func repair() { Task { await model.beginRepair(item) } }
  private func showBook() { Task { await model.showBook(item) } }
  private func trash() { Task { await model.mutateDetail(action: "delete") } }
  private func restore() { Task { await model.mutateDetail(action: "restore") } }
  private func reload() { Task { await model.load() } }
  private func openSourceRecovery() { showingSourceRecovery = true }
  private func reattachSourceDraft(_ draft: NativeAnnotationRecoveryDraft) {
    showingSourceRecovery = false
    Task { await model.beginDraftRepair(draft) }
  }
  private func exportAnnotation() {
    do {
      exportDocument = try model.exportSelection(items: [item])
      showingExporter = true
    } catch { model.error = error.localizedDescription }
  }
  private func exported(_ result: Result<URL, any Error>) {
    if case .failure(let error) = result { model.error = error.localizedDescription }
    exportDocument = nil
  }
}

private struct AnnotationHubDrawingView: View {
  let drawing: NativeAnnotationDrawing

  var body: some View {
    if let encoded = drawing.nativeData, let data = Data(base64Encoded: encoded),
      let retained = try? PKDrawing(data: data), !retained.bounds.isEmpty
    {
      Image(uiImage: retained.image(from: retained.bounds.insetBy(dx: -8, dy: -8), scale: 1))
        .resizable().scaledToFit().frame(maxHeight: 300)
        .background(Color(uiColor: .secondarySystemBackground))
        .accessibilityLabel("Retained handwritten note")
        .accessibilityIdentifier("annotationHubRetainedDrawing")
    } else {
      Label("\(drawing.strokes.count) retained strokes", systemImage: "pencil.tip")
        .accessibilityIdentifier("annotationHubRetainedDrawing")
    }
  }
}

struct AnnotationHubRepairView: View {
  let book: BookDetail
  let format: AnnotationHubRepairFormat
  let choose: (BookDetailFile) -> Void
  @Environment(\.dismiss) private var dismiss

  private var files: [BookDetailFile] {
    book.files.filter(format.supports)
  }

  var body: some View {
    NavigationStack {
      List {
        Section {
          Text(
            "Choose the edition containing this passage, then select the correct passage or page in the reader."
          )
          .fixedSize(horizontal: false, vertical: true)
          Text("The existing note and drawing are preserved until you confirm the new passage.")
            .fixedSize(horizontal: false, vertical: true)
        }
        Section("Editions") {
          ForEach(files) { file in
            Button {
              choose(file)
            } label: {
              VStack(alignment: .leading) {
                Text(file.filename ?? file.format?.uppercased() ?? String(localized: "Book file"))
                Text(file.format?.uppercased() ?? "").foregroundStyle(.secondary)
              }
              .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
              .contentShape(Rectangle())
            }.accessibilityIdentifier("annotationHubRepairFile\(file.id)")
          }
          if files.isEmpty {
            Text(
              "No supported edition is currently available. Export the saved annotation for recovery."
            )
          }
        }
      }
      .font(.body).buttonStyle(.plain).foregroundStyle(Color(uiColor: .label))
      .navigationTitle("Repair passage")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel", action: dismiss.callAsFunction)
        }
      }
    }
  }
}

struct AnnotationHubReaderView: View {
  let model: AnnotationHubModel
  let destination: AnnotationHubReaderDestination

  var body: some View {
    NativeReaderHost(
      api: model.api, bookID: destination.book.id, file: destination.file,
      files: destination.book.files,
      title: destination.book.title ?? String(localized: "Untitled book"),
      language: destination.book.language,
      annotation: destination.repairing ? nil : destination.annotation,
      repairAnnotation: destination.repairing ? destination.annotation : nil,
      onRepairSelection: repaired
    )
    .overlay(alignment: .top) {
      if let error = model.error {
        Text(error).font(.body).fixedSize(horizontal: false, vertical: true).padding()
          .background(.regularMaterial).accessibilityIdentifier("annotationHubRepairError")
      }
    }
  }

  private func repaired(_ payload: NativeAnnotationPayload) {
    Task { await model.repairHere(payload) }
  }
}
