import SwiftUI

struct BookMoveView: View {
  @Bindable var model: BookMoveModel
  let closed: (BookMoveModel) -> Void
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        if let book = model.book {
          Section {
            Text(book.title ?? "Untitled book").font(.title2.bold())
              .fixedSize(horizontal: false, vertical: true)
              .accessibilityIdentifier("moveBookTitle")
            LabeledContent("Current library", value: book.libraryName)
            Text("Move this one book and its server files. Other selected books are not included.")
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        if let message = model.message {
          Section {
            Text(message).fixedSize(horizontal: false, vertical: true)
              .accessibilityIdentifier("moveBookStatus")
          }
        }
        if model.hasUnconfirmedMove {
          Section {
            Text(
              "An earlier move has no completion acknowledgement and may still finish. Current book status and any new preview are checked again before another confirmation."
            )
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("moveBookUncertainty")
          }
        }
        if model.phase == .destination {
          destinations
          if model.target != nil { folders }
          if model.canPreview {
            Section {
              Button("Preview move", action: preview).frame(minHeight: 44)
                .accessibilityIdentifier("previewMoveBook")
            }
          }
        }
        if model.phase == .review, let preview = model.preview {
          review(preview)
        }
        if model.isBusy {
          Section {
            ProgressView(model.phase == .moving ? "Moving server files…" : "Checking move…")
              .accessibilityIdentifier("moveBookProgress")
            if model.phase == .moving {
              Text("Closing the connection cannot undo a file move already started by the server.")
                .fixedSize(horizontal: false, vertical: true)
              Button("Stop waiting", action: model.stop).frame(minHeight: 44)
                .accessibilityIdentifier("stopMoveBook")
            }
          }
        }
        if let progress = model.progress {
          Section("Server progress") {
            LabeledContent("Selected book", value: statusLabel(progress.status))
              .accessibilityIdentifier("moveBookItemResult")
            if let reason = progress.reason {
              Text(reason).fixedSize(horizontal: false, vertical: true)
            }
          }
        }
        if let summary = model.summary {
          Section("Move result") {
            LabeledContent("Processed", value: String(summary.processed))
            LabeledContent("Moved", value: String(summary.succeeded))
            LabeledContent("Merged", value: String(summary.merged))
            LabeledContent("Failed", value: String(summary.failed))
            LabeledContent("Skipped", value: String(summary.skipped))
            if summary.cancelled { Text("The server reported cancellation.") }
          }.accessibilityIdentifier("moveBookSummary")
        }
        if model.canReconcile {
          Section {
            Button("Reload book status", action: reconcile).frame(minHeight: 44)
              .accessibilityIdentifier("reloadMoveBookStatus")
            Button("Prepare a new move", action: prepareAnotherMove).frame(minHeight: 44)
              .accessibilityIdentifier("prepareAnotherBookMove")
            if model.summary == nil {
              Text(
                "The previous request may still finish. Another move needs a fresh preview and confirmation."
              )
              .fixedSize(horizontal: false, vertical: true)
            }
          }
        } else if model.canPrepareAgain, model.phase == .failed || model.phase == .denied {
          Section {
            Button("Reload destinations", action: reload).frame(minHeight: 44)
              .accessibilityIdentifier("reloadBookMoveDestinations")
          }
        }
      }
      .foregroundStyle(.primary)
      .navigationTitle("Move book to library")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(model.didAttemptMove ? "Close" : "Cancel", action: dismiss.callAsFunction)
            .accessibilityIdentifier("cancelMoveBook")
        }
      }
    }
    .task { await model.prepare() }
    .onDisappear {
      closed(model)
      model.detach()
    }
  }

  private var destinations: some View {
    Section("Destination library") {
      TextField("Find destination library", text: $model.destinationSearch)
        .onSubmit(searchDestinations).accessibilityIdentifier("moveDestinationSearch")
      Button("Search libraries", action: searchDestinations).frame(minHeight: 44)
      ForEach(model.destinations) { destination in
        Button {
          Task { await model.chooseDestination(destination) }
        } label: {
          Label(
            destination.name,
            systemImage: model.target?.id == destination.id ? "checkmark.circle" : "books.vertical"
          )
          .frame(minHeight: 44).fixedSize(horizontal: false, vertical: true)
        }.accessibilityIdentifier("moveDestination\(destination.id)")
      }
      if model.destinations.isEmpty {
        Text("No destination libraries with editor access match this search.")
      }
      paging(
        page: model.destinationPage, total: model.destinationTotal,
        previous: model.canPreviousDestinations, next: model.canNextDestinations,
        previousAction: previousDestinations, nextAction: nextDestinations)
      if let target = model.target { LabeledContent("Selected library", value: target.name) }
    }
  }

  private var folders: some View {
    Section("Destination folder") {
      TextField("Find destination folder", text: $model.folderSearch)
        .onSubmit(searchFolders).accessibilityIdentifier("moveFolderSearch")
      Button("Search folders", action: searchFolders).frame(minHeight: 44)
      ForEach(model.folders) { folder in
        Button {
          model.chooseFolder(folder)
        } label: {
          Label(
            folder.path, systemImage: model.folder?.id == folder.id ? "checkmark.circle" : "folder"
          )
          .frame(minHeight: 44).fixedSize(horizontal: false, vertical: true)
        }.accessibilityIdentifier("moveFolder\(folder.id)")
      }
      if model.folders.isEmpty { Text("No destination folders match this search.") }
      paging(
        page: model.folderPage, total: model.folderTotal,
        previous: model.canPreviousFolders, next: model.canNextFolders,
        previousAction: previousFolders, nextAction: nextFolders)
      if let folder = model.folder { LabeledContent("Selected folder", value: folder.path) }
    }
  }

  @ViewBuilder private func review(_ preview: BookMovePreviewResult) -> some View {
    Section("Review this book") {
      if let target = model.target { LabeledContent("Destination library", value: target.name) }
      if let folder = model.folder { LabeledContent("Destination folder", value: folder.path) }
      ForEach(preview.ready, id: \.bookId) { item in
        LabeledContent("Current path", value: item.currentPath)
        LabeledContent("Destination path", value: item.targetPath)
      }
      ForEach(preview.ineligible, id: \.bookId) { item in
        Text(ineligibleLabel(item.reason)).fixedSize(horizontal: false, vertical: true)
        if let detail = item.detail { Text(detail).fixedSize(horizontal: false, vertical: true) }
      }
      if preview.alreadyInTargetCount == 1 { Text("This book is already in this destination.") }
      ForEach(preview.collisions, id: \.bookId) { collision in
        Text(
          collision.kind == "hash_duplicate"
            ? "An identical copy exists in the destination."
            : "A destination path is already occupied."
        )
        .fixedSize(horizontal: false, vertical: true)
        LabeledContent("Current path", value: collision.currentPath)
        LabeledContent("Conflicting path", value: collision.targetPath)
        LabeledContent("Keep both path", value: collision.keepBothPath)
        Picker("Resolve collision", selection: $model.collisionPolicy) {
          Text("Choose what happens").tag("")
          Text("Keep both books").tag("keep_both")
          if collision.kind == "hash_duplicate", collision.existingBookId != nil {
            Text("Merge the identical destination copy").tag("merge")
          }
          Text("Skip this book").tag("skip")
        }.accessibilityIdentifier("moveCollisionPolicy")
        if model.collisionPolicy == "merge" {
          Text(
            "The selected book replaces the identical destination copy. That destination book record and its saved reading data and memberships are removed. The selected book keeps its own data."
          )
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("moveMergeWarning")
        }
      }
    }
    warnings(preview.warnings)
    Section {
      Button(
        model.collisionPolicy == "skip" ? "Confirm skip" : "Confirm move", action: model.confirm
      )
      .frame(minHeight: 44).disabled(!model.canConfirm)
      .accessibilityIdentifier("confirmMoveBook")
      Button("Choose another destination", action: model.backToDestinations).frame(minHeight: 44)
        .accessibilityIdentifier("backToMoveDestinations")
    }
  }

  @ViewBuilder private func warnings(_ warnings: BookMoveWarnings) -> some View {
    if warnings.crossDevice || warnings.layout != nil || !warnings.accessLosers.isEmpty
      || !warnings.koboImpact.isEmpty || !warnings.formatMismatches.isEmpty
    {
      Section("What changes") {
        if warnings.crossDevice {
          Text(
            "Files cross filesystems. The server copies, verifies, and then removes the source files."
          )
        }
        if let layout = warnings.layout {
          Text(
            layout.change == "wrap_into_folder"
              ? "The destination wraps this book in a folder."
              : "The destination moves this book out of its source folder layout.")
        }
        ForEach(warnings.accessLosers, id: \.userId) { user in
          Text("\(user.username) will lose access to this book.")
        }
        ForEach(warnings.koboImpact, id: \.userId) { user in
          Text(
            "\(user.username): this book will leave \(user.deviceCount) Kobo devices on their next sync."
          )
        }
        ForEach(warnings.formatMismatches, id: \.bookId) { item in
          Text(
            "The destination does not allow \(item.format.uppercased()). Review the format before moving."
          )
        }
      }.fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("moveBookWarnings")
    }
  }

  private func paging(
    page: Int, total: Int, previous: Bool, next: Bool,
    previousAction: @escaping () -> Void, nextAction: @escaping () -> Void
  ) -> some View {
    HStack {
      Button("Previous", action: previousAction).disabled(!previous).frame(minHeight: 44)
      Spacer()
      Text("Page \(page + 1), \(total.formatted()) choices").fixedSize(
        horizontal: false, vertical: true)
      Spacer()
      Button("Next", action: nextAction).disabled(!next).frame(minHeight: 44)
    }
  }

  private func statusLabel(_ value: String) -> String {
    switch value {
    case "success": "Moved"
    case "merged": "Moved and merged"
    case "failed": "Failed"
    case "skipped": "Skipped"
    default: "Unknown"
    }
  }

  private func ineligibleLabel(_ value: String) -> String {
    switch value {
    case "book_not_present": "The book is no longer present."
    case "no_content_file": "The book has no content file to move."
    case "multi_file_target_per_file":
      "This multi-file book cannot move to a library organized by individual files."
    case "no_source_access": "Source library access is required."
    case "pattern_unresolved": "The destination file naming pattern could not be resolved."
    case "path_too_long": "The destination path is too long."
    case "path_outside_target_root": "The destination path is outside its library folder."
    default: "The server cannot move this book."
    }
  }

  private func preview() { Task { await model.loadPreview() } }
  private func reload() { Task { await model.prepare() } }
  private func reconcile() { Task { await model.reconcile() } }
  private func prepareAnotherMove() { Task { await model.prepareAnotherMove() } }
  private func searchDestinations() { Task { await model.loadDestinations(page: 0) } }
  private func previousDestinations() {
    Task { await model.loadDestinations(page: model.destinationPage - 1) }
  }
  private func nextDestinations() {
    Task { await model.loadDestinations(page: model.destinationPage + 1) }
  }
  private func searchFolders() { Task { await model.loadFolders(page: 0) } }
  private func previousFolders() { Task { await model.loadFolders(page: model.folderPage - 1) } }
  private func nextFolders() { Task { await model.loadFolders(page: model.folderPage + 1) } }
}
