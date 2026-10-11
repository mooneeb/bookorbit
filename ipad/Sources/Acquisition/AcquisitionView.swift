import SwiftUI
import UniformTypeIdentifiers

struct AcquisitionView: View {
  let api: BookOrbitAPI
  let user: AuthUser
  @State private var model: AcquisitionModel
  @State private var isSelectingFile = false
  @State private var selectionError: String?
  @State private var isReading = false
  init(api: BookOrbitAPI, user: AuthUser) {
    self.api = api
    self.user = user
    _model = State(initialValue: AcquisitionModel(api: api, user: user))
  }
  var body: some View {
    Form {
      Section("Bring books into your library") {
        if user.hasPermission(.bookDockAccess) {
          Button("Select a book file", systemImage: "doc.badge.plus", action: selectFile)
            .accessibilityIdentifier("acquisitionSelectFile").disabled(
              model.isBusy || model.pending != nil)
        }
        if let pending = model.pending {
          Text(pending.filename).lineLimit(3)
          ProgressView(value: model.progress).accessibilityLabel("Uploaded bytes")
            .accessibilityValue("\(model.received) of \(model.uploadSize)")
            .accessibilityIdentifier("acquisitionUploadProgress")
          if model.isUploading {
            Button("Pause upload", action: model.pause).accessibilityIdentifier("acquisitionPause")
          } else {
            Button("Resume upload", action: model.resume).accessibilityIdentifier(
              "acquisitionResume")
            Button("Discard upload", role: .destructive, action: discard).accessibilityIdentifier(
              "acquisitionDiscard")
          }
        }
        if model.isBusy { ProgressView("Working").accessibilityIdentifier("acquisitionWorking") }
        if let message = model.message {
          Text(message).accessibilityIdentifier("acquisitionMessage")
        }
        if let selectionError { Text(selectionError).foregroundStyle(.red) }
        if model.bookID != nil, user.hasPermission(.libraryDownload) {
          Button("Open imported book", systemImage: "book", action: readBook)
            .accessibilityIdentifier("acquisitionRead")
        }
      }
      if model.pendingFinalize != nil {
        Section("Import progress") {
          if let job = model.importJob {
            LabeledContent("Status", value: statusTitle(job.state))
              .accessibilityIdentifier("acquisitionImportStatus")
            ProgressView(value: Double(job.processed), total: Double(max(1, job.total)))
              .accessibilityLabel("Import progress")
              .accessibilityValue("\(job.processed) of \(job.total)")
            Text("\(job.succeeded) imported, \(job.failed) failed")
              .accessibilityIdentifier("acquisitionImportCounts")
            if let error = job.error { Text(error) }
          }
          if model.isFinalizing {
            Button("Pause status updates", action: model.pauseImport)
              .accessibilityIdentifier("acquisitionPauseImport")
          } else {
            Button("Resume import status", action: resumeImport)
              .accessibilityIdentifier("acquisitionResumeImport").disabled(model.isBusy)
            if model.importJob?.state == "failed" {
              Button("Retry failed import", action: retryImport)
                .accessibilityIdentifier("acquisitionRetryImport").disabled(model.isBusy)
            }
            if let state = model.importJob?.state, ["completed", "failed"].contains(state) {
              Button("Close import result", action: dismissImportResult)
                .accessibilityIdentifier("acquisitionDismissImport").disabled(model.isBusy)
            }
          }
        }
      }
      if let selected = model.selected {
        Section("Review metadata") {
          Text(selected.fileName).font(.headline)
          LabeledContent("Status", value: statusTitle(selected.status))
          if let error = selected.errorMessage { Text(error) }
          TextField("Title", text: $model.title).accessibilityIdentifier("acquisitionTitle")
          TextField("Authors, separated by commas", text: $model.authors).accessibilityIdentifier(
            "acquisitionAuthors")
          if !model.canFinalize {
            Text("Library upload permission is required to finalize a book.")
          }
        }
        if model.canFinalize {
          Section("Choose destination") {
            ForEach(model.capabilities?.libraries ?? [], id: \.id) { library in
              Button {
                model.chooseLibrary(library.id)
              } label: {
                Label(
                  library.name,
                  systemImage: model.libraryID == library.id
                    ? "checkmark.circle.fill" : "books.vertical")
              }.accessibilityIdentifier("acquisitionLibrary\(library.id)")
              if model.libraryID == library.id {
                ForEach(library.folders, id: \.id) { folder in
                  Button {
                    model.chooseFolder(folder.id)
                  } label: {
                    Label(
                      folder.name,
                      systemImage: model.folderID == folder.id ? "checkmark.circle.fill" : "folder")
                  }.accessibilityIdentifier("acquisitionFolder\(folder.id)")
                }
              }
            }
            Button("Save and preview import", action: review).accessibilityIdentifier(
              "acquisitionReview"
            )
            .disabled(model.folderID == nil || model.libraryID == nil || model.isBusy)
          }
          if let preview = model.preview {
            Section("Confirm import") {
              ForEach(preview.items, id: \.fileId) { item in
                Text(item.newName ?? item.fileName)
                Text(item.message ?? statusTitle(item.status))
              }
              Button("Finalize import", action: finalize).accessibilityIdentifier(
                "acquisitionFinalize"
              )
              .disabled(!model.canConfirm || model.isBusy)
            }
          }
        }
      }
      Section("Book Dock") {
        TextField("Search staged files", text: $model.search).accessibilityIdentifier(
          "acquisitionSearch")
        Button("Refresh Book Dock", action: refresh).accessibilityIdentifier("acquisitionRefresh")
          .disabled(model.isBusy)
        ForEach(model.files, id: \.id) { file in
          Button {
            model.select(file)
          } label: {
            VStack(alignment: .leading) {
              Text(file.selectedMetadata?.title ?? file.fileName)
              Text(statusTitle(file.status)).font(.caption).foregroundStyle(.secondary)
            }
          }.accessibilityIdentifier("acquisitionDock\(file.id)").disabled(model.isBusy)
        }
        if model.files.isEmpty { Text("No staged books on this page.") }
        HStack {
          Button("Previous page", action: previous).disabled(model.page <= 1 || model.isBusy)
          Spacer()
          Text("Page \(model.page)")
          Spacer()
          Button("Next page", action: next).disabled(model.page * 20 >= model.total || model.isBusy)
        }
      }
    }
    .navigationTitle("Acquire books")
    .task { await model.prepare() }
    .onDisappear { model.pauseImport() }
    .fileImporter(
      isPresented: $isSelectingFile, allowedContentTypes: [.item], allowsMultipleSelection: false,
      onCompletion: fileSelected
    )
    .sheet(isPresented: $isReading) {
      if let id = model.bookID {
        BookDetailView(
          api: api, bookID: id, canEditMetadata: user.hasPermission(.libraryEditMetadata),
          canRead: user.hasPermission(.libraryDownload),
          canDeleteBooks: user.hasPermission(.libraryDeleteBooks), userID: user.id)
      }
    }
  }
  private func statusTitle(_ status: String) -> String {
    switch status {
    case "queued": String(localized: "Import queued")
    case "running": String(localized: "Importing")
    case "completed": String(localized: "Import completed")
    case "failed": String(localized: "Import needs recovery")
    case "pending": String(localized: "Waiting to process")
    case "extracting": String(localized: "Reading file metadata")
    case "fetching": String(localized: "Fetching metadata")
    case "ready": String(localized: "Ready")
    case "error": String(localized: "Needs attention")
    case "duplicate": String(localized: "Already in the library")
    case "destination_conflict": String(localized: "Another file uses this destination")
    case "missing_destination": String(localized: "Choose a destination")
    case "access_denied": String(localized: "Destination access is required")
    case "invalid_format": String(localized: "This destination does not accept the file format")
    case "unsupported_layout":
      String(localized: "This destination cannot store all files in this book")
    default: String(localized: "Review this staged book before importing")
    }
  }
  private func selectFile() {
    selectionError = nil
    isSelectingFile = true
  }
  private func fileSelected(_ result: Result<[URL], Error>) {
    switch result {
    case .success(let urls): if let url = urls.first { Task { await model.stage(url) } }
    case .failure(let error): selectionError = error.localizedDescription
    }
  }
  private func readBook() { isReading = true }
  private func refresh() { Task { await model.reload() } }
  private func previous() { Task { await model.reload(page: model.page - 1) } }
  private func next() { Task { await model.reload(page: model.page + 1) } }
  private func discard() { Task { await model.discard() } }
  private func review() { Task { await model.review() } }
  private func finalize() { Task { await model.finalize() } }
  private func resumeImport() { model.resumeImport() }
  private func retryImport() { model.resumeImport(retryFailed: true) }
  private func dismissImportResult() { Task { await model.dismissImportResult() } }
}
