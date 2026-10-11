import SwiftUI

struct MaintenanceView: View {
  @State private var model: MaintenanceModel

  init(api: BookOrbitAPI, user: AuthUser) {
    _model = State(initialValue: MaintenanceModel(api: api, user: user))
  }

  var body: some View {
    @Bindable var model = model
    List {
      Section {
        Picker("Maintenance tool", selection: $model.tool) {
          ForEach(model.tools) { tool in Text(tool.rawValue).tag(tool) }
        }
        .accessibilityIdentifier("maintenanceTool")
        Picker("Library", selection: $model.libraryID) {
          ForEach(model.libraries) { library in Text(library.name).tag(Optional(library.id)) }
        }
        .accessibilityIdentifier("maintenanceLibrary")
      }
      if let error = model.error {
        Section("Action needs attention") {
          Text(error).foregroundStyle(.red).accessibilityIdentifier("maintenanceError")
          Button("Refresh and retry") { Task { await model.refresh() } }
            .accessibilityIdentifier("maintenanceRetry")
        }
      }
      if let result = model.result {
        Section("Result") { Text(result).accessibilityIdentifier("maintenanceResult") }
      }
      if !model.progress.isEmpty {
        Section("Progress") { Text(model.progress).accessibilityIdentifier("maintenanceProgress") }
      }
      if model.isBusy {
        Section {
          ProgressView("Working on the server")
          Button("Stop", role: .cancel, action: model.cancel)
        }
      }
      switch model.tool {
      case .duplicates: duplicateSections
      case .rename: renameSections
      case .missing: missingSections
      }
      Section {
        Text("Page \(model.page), \(model.total) results")
          .accessibilityIdentifier("maintenancePage")
        HStack {
          if model.page > 1 { Button("Previous") { Task { await model.previous() } } }
          Spacer()
          if model.canNext { Button("Next") { Task { await model.next() } } }
        }
      }
    }
    .navigationTitle("Maintenance")
    .toolbar {
      Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
        .disabled(model.isBusy).accessibilityIdentifier("maintenanceRefresh")
    }
    .task { await model.load() }
    .onChange(of: model.tool) { _, _ in Task { await model.refresh() } }
    .onChange(of: model.libraryID) { _, _ in Task { await model.refresh() } }
    .sheet(
      item: Binding(
        get: { model.merge.map { MergeSelection(preview: $0) } },
        set: { if $0 == nil { model.merge = nil } }
      )
    ) { selection in
      NavigationStack {
        Form {
          Section("Merge preview") {
            Text("Keep book \(selection.preview.targetBookId)")
            Text("Merge book \(selection.preview.sourceBookId)")
            Text("Preserve \(selection.preview.filesPreserved) files and their reading data")
            ForEach(selection.preview.blockers, id: \.self) { Text($0) }
          }
          if selection.preview.canApply {
            Button("Apply merge", role: .destructive, action: model.applyMerge)
              .disabled(model.isBusy).accessibilityIdentifier("maintenanceApplyMerge")
          }
        }
        .navigationTitle("Review merge")
        .toolbar { Button("Cancel") { model.merge = nil } }
      }
    }
    .sheet(
      item: Binding(
        get: { model.repair.map { RepairSelection(preview: $0) } },
        set: { if $0 == nil { model.repair = nil } }
      )
    ) { selection in
      NavigationStack {
        Form {
          Section("Repair preview") {
            Text("Book \(selection.preview.bookId), file \(selection.preview.fileId)")
            LabeledContent("Missing path", value: selection.preview.currentPath)
            LabeledContent("Replacement", value: selection.preview.replacementPath)
            Text(
              "\(selection.preview.sizeBytes) bytes verified. File identity and reading data will be preserved."
            )
          }
          Button("Apply repair", action: model.applyRepair)
            .disabled(model.isBusy).accessibilityIdentifier("maintenanceApplyRepair")
        }
        .navigationTitle("Review repair")
        .toolbar { Button("Cancel") { model.repair = nil } }
      }
    }
  }

  private var duplicateSections: some View {
    Group {
      Section("Duplicate detection") {
        Button("Scan for duplicates", action: model.startScan)
          .disabled(model.isBusy).accessibilityIdentifier("maintenanceScan")
        if let scan = model.scan { Text("Scan \(scan.id): \(scan.status)") }
      }
      ForEach(model.groups, id: \.id) { group in
        Section("Duplicate group \(group.id)") {
          if model.canMerge, let initial = group.books.first {
            Picker(
              "Keep book",
              selection: Binding(
                get: { model.mergeTargets[group.id] ?? initial.id },
                set: { model.mergeTargets[group.id] = $0 }
              )
            ) {
              ForEach(group.books, id: \.id) { book in
                Text("Keep book \(book.id): \(book.title ?? "Untitled")").tag(book.id)
              }
            }
            .accessibilityIdentifier("maintenanceKeeper\(group.id)")
          }
          ForEach(group.books, id: \.id) { book in
            VStack(alignment: .leading) {
              Text(book.title ?? "Untitled")
              Text("Book \(book.id), \(book.files.count) files").font(.caption)
              if model.canMerge, let initial = group.books.first,
                (model.mergeTargets[group.id] ?? initial.id) != book.id
              {
                Button("Preview merge") {
                  model.previewMerge(
                    source: book.id, target: model.mergeTargets[group.id] ?? initial.id)
                }
                .disabled(model.isBusy).accessibilityIdentifier("maintenanceMerge\(book.id)")
              }
            }
          }
        }
      }
    }
  }

  private var renameSections: some View {
    Group {
      Section("Rename preview") {
        Text(
          "Select the books to rename on this page. The server checks collisions again before moving files."
        )
        ForEach(model.renames, id: \.bookId) { item in
          VStack(alignment: .leading) {
            if item.status == "will_rename" {
              Toggle(
                item.title,
                isOn: Binding(
                  get: { model.selectedBookIDs.contains(item.bookId) },
                  set: {
                    if $0 {
                      model.selectedBookIDs.insert(item.bookId)
                    } else {
                      model.selectedBookIDs.remove(item.bookId)
                    }
                  }
                )
              )
              .accessibilityIdentifier("maintenanceRename\(item.bookId)")
            } else {
              Text(item.title)
            }
            Text(item.currentPath).font(.caption)
            if let path = item.newPath { Text(path).font(.caption) }
            Text(item.reason ?? item.status).font(.caption)
          }
        }
        Button("Apply selected renames", action: model.applyRename)
          .disabled(model.isBusy || model.selectedBookIDs.isEmpty)
          .accessibilityIdentifier("maintenanceApplyRename")
      }
    }
  }

  private var missingSections: some View {
    Group {
      Section("Missing books") {
        ForEach(model.missing, id: \.id) { book in
          Button {
            model.selectMissing(book)
          } label: {
            VStack(alignment: .leading) {
              Text(book.title ?? "Untitled")
              Text("Book \(book.id): \(book.folderPath)").font(.caption)
            }
          }
          .accessibilityIdentifier("maintenanceMissing\(book.id)")
        }
      }
      if model.canRepair {
        Section("Repair a moved file") {
          Text("Choose a missing book above, then select its file.")
          Picker(
            "File to repair",
            selection: Binding(get: { model.repairFileID }, set: { model.repairFileID = $0 })
          ) {
            ForEach(model.repairFiles) { file in
              Text(file.filename ?? "\(file.format?.uppercased() ?? "Book") file").tag(
                String(file.id))
            }
          }
          .accessibilityIdentifier("maintenanceRepairFile")
          TextField(
            "Replacement path on server",
            text: Binding(get: { model.replacementPath }, set: { model.replacementPath = $0 })
          )
          .textInputAutocapitalization(.never).autocorrectionDisabled()
          .accessibilityIdentifier("maintenanceReplacementPath")
          Button("Preview repair", action: model.previewRepair)
            .disabled(model.isBusy).accessibilityIdentifier("maintenancePreviewRepair")
        }
      }
      Section("Cover cleanup preview") {
        Button("Review cover cleanup", action: model.reviewCoverCleanup).disabled(model.isBusy)
          .accessibilityIdentifier("maintenanceReviewCleanup")
        ForEach(model.brokenCovers, id: \.id) { cover in Text(cover.title ?? "Untitled") }
        if model.canCleanBrokenCovers, !model.brokenCovers.isEmpty {
          Button("Clear listed broken cover references", role: .destructive) {
            model.cleanupCategory = "broken-covers"
          }
          .disabled(model.isBusy).accessibilityIdentifier("maintenanceCleanBrokenCovers")
        }
        ForEach(model.orphanedCovers, id: \.bookId) { cover in
          Text("Deleted book \(cover.bookId): \(cover.fileCount) cover files")
        }
        if model.canCleanOrphanedCovers, !model.orphanedCovers.isEmpty {
          Button("Remove listed orphaned cover folders", role: .destructive) {
            model.cleanupCategory = "orphaned-covers"
          }
          .disabled(model.isBusy).accessibilityIdentifier("maintenanceCleanOrphanedCovers")
        }
      }
      Section("Cover check") {
        Button("Check covers", action: model.startSweep).disabled(model.isBusy)
          .accessibilityIdentifier("maintenanceSweep")
        if let sweep = model.summary?.sweep {
          Text(
            "\(sweep.processedBooks) checked, \(sweep.brokenCovers) broken covers, \(sweep.orphanedCoverDirs) orphaned folders"
          )
        }
      }
    }
  }
}

private struct MergeSelection: Identifiable {
  let preview: MergeBooksPreview
  var id: Int { preview.sourceBookId }
}

private struct RepairSelection: Identifiable {
  let preview: MissingFileRepairPreview
  var id: Int { preview.fileId }
}
