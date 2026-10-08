import SwiftUI

struct BookFileActionsView: View {
  @Bindable var model: BookFileActionsModel
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        if let file = model.file {
          Section("Selected file") {
            Text(file.filename ?? "Book file").font(.headline)
              .fixedSize(horizontal: false, vertical: true)
              .accessibilityIdentifier("managedFileName")
            LabeledContent("Format", value: file.format?.uppercased() ?? "Unknown")
            LabeledContent("Role", value: file.role.capitalized)
            if let size = file.sizeBytes {
              LabeledContent(
                "Size",
                value: ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
            }
            Text(file.absolutePath).font(.caption)
              .fixedSize(horizontal: false, vertical: true)
              .accessibilityLabel("Server path, \(file.absolutePath)")
              .accessibilityIdentifier("managedFileServerPath")
          }
        }
        if let message = model.message {
          Section {
            Text(message).fixedSize(horizontal: false, vertical: true)
              .accessibilityIdentifier("fileActionMessage")
          }
        }
        if model.isBusy {
          Section {
            if let progress = model.progress {
              ProgressView(value: Double(progress.received), total: Double(max(1, progress.total)))
                .accessibilityLabel("File download")
              Text("\(bytes(progress.received)) of \(bytes(progress.total))")
                .accessibilityIdentifier("fileDownloadProgress")
            } else {
              ProgressView("Checking file or waiting for the server…")
            }
            if model.isDownloading {
              Button("Cancel download", action: model.cancelDownload).frame(minHeight: 44)
                .accessibilityIdentifier("cancelFileDownload")
            }
          }
        }
        if model.isEditingRename {
          renameSection
        } else if model.isConfirmingDelete {
          deleteSection
        } else if let artifact = model.staged {
          Section("Downloaded file") {
            Text(artifact.filename).fixedSize(horizontal: false, vertical: true)
              .accessibilityIdentifier("downloadedFileName")
            Text(
              "\(bytes(artifact.size)). This temporary copy is removed when you close or finish delivery."
            )
            .fixedSize(horizontal: false, vertical: true)
            Button("Save to Files", action: save).frame(minHeight: 44)
              .accessibilityIdentifier("saveDownloadedFile")
            Button("Share file", action: share).frame(minHeight: 44)
              .accessibilityIdentifier("shareDownloadedFile")
            Button("Discard download", action: model.discardDownload).frame(minHeight: 44)
              .accessibilityIdentifier("discardDownloadedFile")
          }
        } else if model.file != nil {
          Section("File actions") {
            if model.canDownload {
              Button("Download file", action: download).frame(minHeight: 44)
                .accessibilityIdentifier("downloadManagedFile")
            }
            if model.canDownloadWithoutAudio {
              Button("Download EPUB without audio", action: downloadWithoutAudio).frame(
                minHeight: 44
              )
              .accessibilityIdentifier("downloadAudiolessEPUB")
              Text(
                "Creates a separate EPUB without recorded narration. The original file and Read Along remain unchanged."
              )
              .font(.caption).fixedSize(horizontal: false, vertical: true)
            }
            if model.canCopyPath {
              Button("Copy server path", action: copyPath).frame(minHeight: 44)
                .accessibilityIdentifier("copyManagedFileServerPath")
            }
            if model.canRename {
              Button("Rename file", action: model.beginRename).frame(minHeight: 44)
                .accessibilityIdentifier("renameManagedFile")
            }
            if model.canDelete {
              Button("Delete file", role: .destructive, action: model.beginDelete).frame(
                minHeight: 44
              )
              .accessibilityIdentifier("deleteManagedFile")
            }
          }
        }
        if let book = model.book, model.file == nil, !model.isBusy {
          Section("Book after file change") {
            LabeledContent("Status", value: book.status.capitalized)
            LabeledContent("Remaining files", value: String(book.files.count))
            if let primary = book.files.first(where: { $0.role == "primary" }) {
              Text("Primary file: \(primary.filename ?? "Book file")")
                .fixedSize(horizontal: false, vertical: true)
            }
          }
        }
        Section {
          Button("Reload current file details", action: reload).frame(minHeight: 44)
            .disabled(model.isBusy || model.isClosed || model.staged != nil)
            .accessibilityIdentifier("reloadManagedFile")
        }
      }
      .navigationTitle("Manage file")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done", action: close).disabled(model.isMutating)
            .accessibilityIdentifier("closeFileActions")
        }
      }
    }
    .task { await model.reload() }
    .interactiveDismissDisabled(model.isMutating)
    .onDisappear(perform: model.close)
    .sheet(item: $model.delivery, onDismiss: model.discardDownload) { presentation in
      BookFileDeliveryView(presentation: presentation, completed: model.finishDelivery)
    }
  }

  private var renameSection: some View {
    Section("Rename file") {
      if let file = model.file {
        Text("Current filename: \(file.filename ?? "Book file")")
          .fixedSize(horizontal: false, vertical: true)
      }
      TextField("Filename including extension", text: $model.renameFilename, axis: .vertical)
        .textInputAutocapitalization(.never).autocorrectionDisabled()
        .disabled(model.isBusy)
        .accessibilityIdentifier("renameFileInput")
      Text(
        "Include the full filename and extension. Renaming preserves the file identity and does not convert its format."
      )
      .font(.caption).fixedSize(horizontal: false, vertical: true)
      if let validation = model.renameValidation {
        Text(validation).fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("renameFileValidation")
      }
      Button("Save filename", action: rename).frame(minHeight: 44)
        .disabled(!model.canRename || model.renameValidation != nil)
        .accessibilityIdentifier("saveFileRename")
      Button("Cancel rename", action: model.cancelRename).frame(minHeight: 44)
        .disabled(model.isBusy).accessibilityIdentifier("cancelFileRename")
    }
  }

  private var deleteSection: some View {
    Section("Confirm file deletion") {
      if let file = model.file {
        Text("Delete \(file.filename ?? "this file") from the server?")
          .font(.headline).fixedSize(horizontal: false, vertical: true)
      }
      Text(
        "This permanently removes this selected file. The book record remains. The server may choose another primary file. If this is the last file, the book has no files and no primary file. You cannot undo this action here."
      )
      .fixedSize(horizontal: false, vertical: true)
      Button("Delete selected file", role: .destructive, action: delete).frame(minHeight: 44)
        .disabled(!model.canDelete).accessibilityIdentifier("confirmDeleteManagedFile")
      Button("Cancel deletion", action: model.cancelDelete).frame(minHeight: 44)
        .disabled(model.isBusy).accessibilityIdentifier("cancelDeleteManagedFile")
    }
  }

  private func bytes(_ size: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
  }

  private func reload() { Task { await model.reload() } }
  private func rename() { Task { await model.rename() } }
  private func delete() { Task { await model.delete() } }
  private func copyPath() { Task { await model.copyPath() } }
  private func download() { model.download(.original) }
  private func downloadWithoutAudio() { model.download(.withoutAudio) }
  private func save() { Task { await model.presentDelivery(.save) } }
  private func share() { Task { await model.presentDelivery(.share) } }
  private func close() {
    model.close()
    dismiss()
  }
}
