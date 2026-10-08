import SwiftUI

struct OfflineBookView: View {
  @State private var model: OfflineBookModel
  @Environment(\.dismiss) private var dismiss

  init(api: BookOrbitAPI, book: BookDetail) {
    _model = State(initialValue: OfflineBookModel(api: api, book: book))
  }

  var body: some View {
    NavigationStack {
      List {
        Section("Content to keep on this iPad") {
          Text(
            "Choose each file, media track, or companion document. Metadata, covers, all your annotations, bookmarks, and progress are always included, even for files you leave unselected."
          )
          .fixedSize(horizontal: false, vertical: true)
          ForEach(model.book.files) { file in
            Button {
              model.toggle(file)
            } label: {
              HStack {
                Image(
                  systemName: model.selectedFileIDs.contains(file.id)
                    ? "checkmark.circle.fill" : "circle")
                VStack(alignment: .leading) {
                  Text(file.filename ?? file.format?.uppercased() ?? "File \(file.id)")
                    .fixedSize(horizontal: false, vertical: true)
                  Text(file.role).font(.caption).foregroundStyle(.secondary)
                  if let size = file.sizeBytes, size.isFinite, size >= 0, size < Double(Int64.max) {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                      .font(.caption).foregroundStyle(.secondary)
                  }
                }
              }.frame(minHeight: 44)
            }
            .disabled(model.isBusy)
            .accessibilityIdentifier("offlineSelectFile\(file.id)")
            .accessibilityValue(
              model.selectedFileIDs.contains(file.id) ? "Selected" : "Not selected")
          }
        }
        Section("Download") {
          Text(model.status).fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("offlineStatus")
          Text(model.bytesLabel).font(.caption).accessibilityIdentifier("offlineBytes")
          if let snapshot = model.snapshot, snapshot.knownBytes > 0 {
            ProgressView(value: Double(snapshot.receivedBytes), total: Double(snapshot.knownBytes))
              .accessibilityLabel("Downloaded content")
          }
          if let error = model.error {
            Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
              .accessibilityIdentifier("offlineError")
          }
          if model.isBusy {
            Button("Pause", action: model.pause).frame(minHeight: 44).accessibilityIdentifier(
              "offlinePause")
          } else if model.snapshot?.state == "paused" {
            Button("Resume", action: model.start).frame(minHeight: 44).accessibilityIdentifier(
              "offlineResume")
          } else if model.snapshot?.state == "failed" {
            Button("Retry", action: model.start).frame(minHeight: 44).accessibilityIdentifier(
              "offlineRetry")
          } else {
            Button("Download selected content", action: model.start).frame(minHeight: 44)
              .disabled(model.selectedFileIDs.isEmpty).accessibilityIdentifier("offlineDownload")
          }
          Text(
            "Downloads use at most 4 GB and 500 selected books. Pending annotations stay protected in separate account storage."
          )
          .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
      }
      .navigationTitle("Offline resources")
      .toolbar { Button("Done", action: dismiss.callAsFunction).disabled(model.isBusy) }
    }
    .interactiveDismissDisabled(model.isBusy)
    .task { await model.load() }
  }
}

struct OfflineLibraryView: View {
  let api: BookOrbitAPI
  let user: AuthUser?
  @Environment(\.dismiss) private var dismiss
  @State private var books: [OfflineBookSummary] = []
  @State private var selected: OfflineBookSummary?
  @State private var reviewingRecovery = false
  @State private var error: String?

  var body: some View {
    NavigationStack {
      List {
        if let error { Text(error).fixedSize(horizontal: false, vertical: true) }
        if books.isEmpty {
          Text("Choose Offline resources from a book's details to download its selected content.")
            .fixedSize(horizontal: false, vertical: true)
        }
        ForEach(books) { snapshot in
          Button {
            selected = snapshot
          } label: {
            VStack(alignment: .leading) {
              Text(snapshot.title).fixedSize(
                horizontal: false, vertical: true)
              Text(
                snapshot.state == "ready"
                  ? "Verified ready for offline reading" : "Download \(snapshot.state)"
              )
              .font(.caption).foregroundStyle(.secondary)
              Text("\(snapshot.selectedFileCount) selected files").font(.caption)
                .foregroundStyle(.secondary)
            }.frame(minHeight: 44)
          }.accessibilityIdentifier("offlineBook\(snapshot.id)")
        }
      }
      .navigationTitle("Offline books")
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("Source recovery") { reviewingRecovery = true }.accessibilityIdentifier(
            "offlineSourceRecovery")
        }
        ToolbarItem(placement: .topBarTrailing) { Button("Done", action: dismiss.callAsFunction) }
      }
    }
    .task {
      do { books = try await api.offlineStore().summaries() } catch {
        self.error = error.localizedDescription
      }
    }
    .sheet(isPresented: $reviewingRecovery) { SourceRecoveryView(api: api) }
    .sheet(item: $selected) { snapshot in
      BookDetailView(
        api: api, bookID: snapshot.id, canEditMetadata: false,
        canRead: user?.hasPermission(.libraryDownload) == true, userID: user?.id ?? 0)
    }
  }
}
