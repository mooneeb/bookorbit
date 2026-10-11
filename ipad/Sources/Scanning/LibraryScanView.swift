import SwiftUI

struct LibraryScanView: View {
  let api: BookOrbitAPI
  let user: AuthUser
  let library: Library
  @State private var model: LibraryScanModel
  @State private var selectedBook: BookCard?
  @State private var confirming = false

  init(api: BookOrbitAPI, user: AuthUser, library: Library) {
    self.api = api
    self.user = user
    self.library = library
    _model = State(initialValue: LibraryScanModel(api: api, libraryID: library.id, userID: user.id))
  }
  private var canEdit: Bool {
    user.hasPermission(.manageLibraries)
      && (user.isSuperuser || ["editor", "owner"].contains(library.accessLevel ?? ""))
  }
  var body: some View {
    @Bindable var model = model
    List {
      if let message = model.message {
        Section {
          Text(message).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier(
            "libraryScanNotice")
        }
      }
      if model.isBusy {
        ProgressView("Checking server scan…").accessibilityIdentifier("libraryScanBusy")
      }
      if canEdit, model.configuration != nil {
        Section("Server folder configuration") {
          TextField("Server paths, one per line", text: $model.paths, axis: .vertical).lineLimit(
            2...5
          ).accessibilityIdentifier("scanFolderPaths")
          Toggle("Watch for file changes", isOn: $model.watch).accessibilityIdentifier(
            "scanWatchFolders")
          TextField("Automatic scan cron expression", text: $model.cron).autocorrectionDisabled()
            .textInputAutocapitalization(.never).accessibilityIdentifier("scanCronExpression")
          Picker("Organization", selection: $model.organizationMode) {
            Text("One book per file").tag("book_per_file")
            Text("One book per folder").tag("book_per_folder")
          }.accessibilityIdentifier("scanOrganization")
          TextField(
            "Allowed formats, one per line. Empty allows all", text: $model.allowedFormats,
            axis: .vertical
          ).lineLimit(1...3).accessibilityIdentifier("scanAllowedFormats")
          TextField("Excluded patterns, one per line", text: $model.exclusions, axis: .vertical)
            .lineLimit(1...3).accessibilityIdentifier("scanExcludedPatterns")
          Button("Preview server folders", action: preview).disabled(
            model.isBusy || !model.validConfiguration
          ).accessibilityIdentifier("previewServerScan")
          Button("Save scan configuration", action: save).disabled(
            model.isBusy || !model.validConfiguration || !model.hasUnsavedConfiguration
              || model.progress?.status == "running" || model.retryBaseline != nil
          ).accessibilityIdentifier("saveServerScanConfiguration")
          Text(
            "Saving changed scan settings schedules a scan on the server. Paths refer to the server filesystem."
          )
        }
      }
      if let preview = model.preview {
        Section("Folder preview") {
          LabeledContent("Supported files") {
            Text(String(preview.totalFiles)).accessibilityIdentifier("scanPreviewCount")
          }
          ForEach(Array(preview.paths.enumerated()), id: \.offset) { _, path in
            VStack(alignment: .leading) {
              Text(path.path).font(.caption).textSelection(.enabled)
              Text(path.accessible ? "Accessible: \(path.fileCount) files" : "Folder unavailable")
              if let error = path.error { Text(error).foregroundStyle(.secondary) }
              if let overlap = path.overlapLibrary { Text("Overlaps library: \(overlap)") }
            }
          }
          if canEdit {
            Button("Start library scan", action: confirm).disabled(!model.canStart)
              .accessibilityIdentifier("startServerScan")
          }
        }
      }
      if let progress = model.progress {
        Section("Server progress") {
          LabeledContent("Job") {
            Text(String(progress.jobId)).accessibilityIdentifier("serverScanJobID")
          }
          LabeledContent("Status") {
            Text(progress.status).accessibilityIdentifier("serverScanStatus")
          }
          if progress.status == "running" {
            if progress.total > 0 {
              ProgressView(
                value: Double(min(progress.processed, progress.total)),
                total: Double(progress.total))
            } else {
              ProgressView("Discovering server files…")
            }
            Text("\(progress.processed) of \(progress.total) processed")
          }
          Text("Added \(progress.added), updated \(progress.updated), missing \(progress.missing)")
          if let error = progress.errorMessage {
            Text(error).fixedSize(horizontal: false, vertical: true)
          }
        }
      }
      Section {
        Button("Reload scan status", action: reloadStatus).disabled(model.isBusy)
          .accessibilityIdentifier("reloadLibraryScanStatus")
        if model.retryBaseline != nil && canEdit {
          Button("Retry original scan request", action: retry).disabled(model.isBusy)
            .accessibilityIdentifier("retryOriginalServerScan")
        }
      }
      Section("Recent scans") {
        ForEach(model.history) { job in
          VStack(alignment: .leading) {
            Text("Job \(job.id): \(job.status)").font(.headline)
            Text("\(job.triggeredBy) at \(job.startedAt)").font(.caption)
            Text(
              "Added \(job.addedCount), updated \(job.updatedCount), missing \(job.missingCount)")
            if let error = job.errorMessage { Text(error).foregroundStyle(.secondary) }
          }
        }
        if model.history.isEmpty { Text("No scans recorded.") }
        Text("Showing the five most recent scans.").font(.caption)
      }
      Section("Library books") {
        TextField("Find a scanned book", text: $model.bookSearch).onSubmit(search)
          .accessibilityIdentifier("scanBookSearch")
        Button("Search library books", action: search).disabled(model.isBusy)
          .accessibilityIdentifier("searchScanBooks")
        ForEach(model.books) { book in
          Button {
            selectedBook = book
          } label: {
            Text(book.title ?? "Untitled book")
          }.accessibilityIdentifier("scanOpenBook_\(book.id)")
        }
        HStack {
          Button("Previous", action: previous).disabled(model.isBusy || model.bookPage == 0)
          Spacer()
          Text("Page \(model.bookPage + 1)")
          Spacer()
          Button("Next", action: next).disabled(
            model.isBusy || (model.bookPage + 1) * 40 >= model.bookTotal)
        }
      }
    }
    .navigationTitle(library.name)
    .task {
      await model.load()
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(3)) } catch { break }
        if model.shouldMonitorStatus {
          await model.refreshStatus()
        }
      }
    }
    .confirmationDialog(
      "Scan configured server folders?", isPresented: $confirming, titleVisibility: .visible
    ) {
      Button("Start scan", action: start)
    } message: {
      Text(
        "Files are adopted in place. Existing library metadata and reading data are preserved by the server scanner."
      )
    }
    .sheet(item: $selectedBook) { book in
      BookDetailView(
        api: api, bookID: book.id, canEditMetadata: user.hasPermission(.libraryEditMetadata),
        canRead: user.hasPermission(.libraryDownload),
        canDeleteBooks: user.hasPermission(.libraryDeleteBooks), userID: user.id)
    }
  }
  private func preview() { Task { await model.previewFolders() } }
  private func save() { Task { await model.save() } }
  private func confirm() { confirming = true }
  private func start() { Task { await model.start() } }
  private func retry() { Task { await model.retry() } }
  private func reloadStatus() { Task { await model.refreshStatus() } }
  private func search() { Task { await model.searchBooks() } }
  private func previous() { Task { await model.previousBooks() } }
  private func next() { Task { await model.nextBooks() } }
}
