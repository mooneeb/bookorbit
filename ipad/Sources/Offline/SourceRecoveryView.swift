import SwiftUI

struct SourceRecoveryView: View {
  @State private var model: SourceRecoveryModel
  private let reattachDraft: (@MainActor (NativeAnnotationRecoveryDraft) -> Void)?
  @Environment(\.dismiss) private var dismiss

  init(
    api: BookOrbitAPI, bookID: Int? = nil, fileID: Int? = nil,
    reattachDraft: (@MainActor (NativeAnnotationRecoveryDraft) -> Void)? = nil
  ) {
    _model = State(initialValue: SourceRecoveryModel(api: api, bookID: bookID, fileID: fileID))
    self.reattachDraft = reattachDraft
  }

  var body: some View {
    NavigationStack {
      List {
        Section {
          Text(
            "Retained versions preserve downloaded content when a source file changes or is deleted. Export a complete version, then choose a recovery draft to attach to a current edition and confirm its passage or page."
          )
          .fixedSize(horizontal: false, vertical: true)
        }
        if model.isBusy {
          Section {
            ProgressView("Preparing source recovery…").accessibilityIdentifier(
              "sourceRecoveryLoading")
          }
        }
        if let error = model.error {
          Section("Recovery status") {
            Text(error).accessibilityIdentifier("sourceRecoveryError")
            Button("Try again", action: model.reload).frame(minHeight: 44)
              .disabled(model.isBusy).accessibilityIdentifier("sourceRecoveryRetry")
          }
        }
        ForEach(model.versions) { version in versionSection(version) }
        if !model.isBusy, model.versions.isEmpty {
          Section {
            Text("No retained source versions are saved on this iPad.").accessibilityIdentifier(
              "sourceRecoveryEmpty")
          }
        }
        if !model.drafts.isEmpty {
          Section("Recent annotation recovery drafts") {
            ForEach(model.drafts) { draft in draftRow(draft) }
          }
        }
        Section {
          Button("Previous versions", action: model.previous).frame(minHeight: 44)
            .disabled(model.previousCursors.isEmpty || model.isBusy).accessibilityIdentifier(
              "sourceRecoveryPreviousPage")
          Button("Next versions", action: model.next).frame(minHeight: 44)
            .disabled(model.nextCursor == nil || model.isBusy).accessibilityIdentifier(
              "sourceRecoveryNextPage")
        }
      }
      .buttonStyle(.plain).font(.body).accessibilityIdentifier("sourceRecoveryList")
      .navigationTitle("Retained source versions").navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done", action: dismiss.callAsFunction).accessibilityIdentifier(
            "sourceRecoveryClose")
        }
      }
      .task { await model.load() }
      .onDisappear(perform: model.close)
      .confirmationDialog(
        "Remove this retained source version?", isPresented: $model.confirmsRemoval,
        titleVisibility: .visible
      ) {
        Button("Remove retained version", role: .destructive, action: model.removeConfirmed)
          .accessibilityIdentifier("sourceRecoveryConfirmRemove")
        Button("Cancel", role: .cancel, action: model.cancelRemoval)
      } message: {
        Text(
          "The retained copy is removed from this iPad. Versions needed by pending work or recovery drafts remain protected."
        )
      }
    }
  }

  private func versionSection(_ version: OfflineSourceVersion) -> some View {
    Section {
      Text(version.title).font(.headline).fixedSize(horizontal: false, vertical: true)
      Text(version.reason == "source_deleted" ? "Source deleted" : "Source replaced")
        .font(.subheadline.weight(.semibold)).accessibilityIdentifier("sourceRecoveryState")
      Text(version.filename).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
      Text("Book \(version.bookID), file \(version.fileID), \(version.format.uppercased())")
        .font(.caption).accessibilityIdentifier("sourceRecoveryProvenance")
      Text(ByteCountFormatter.string(fromByteCount: version.sizeBytes, countStyle: .file)).font(
        .caption)
      Text(version.capturedAt, format: Date.FormatStyle(date: .abbreviated, time: .shortened)).font(
        .caption)
      Text("Revision \(version.revision)").font(.caption.monospaced()).textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier(
          "sourceRecoveryRevision")
      if model.exportedVersionID == version.id, let artifact = model.artifact {
        Text("Verified complete export: \(artifact.filename)").font(.caption)
          .accessibilityIdentifier("sourceRecoveryExportReady")
        ShareLink(item: artifact.url) {
          Label("Export retained source", systemImage: "square.and.arrow.up")
        }
        .frame(minHeight: 44).accessibilityIdentifier("sourceRecoveryExport\(version.id)")
      } else {
        Button("Prepare retained source export") { model.prepareExport(version) }.frame(
          minHeight: 44
        )
        .disabled(model.isBusy).accessibilityIdentifier("sourceRecoveryPrepareExport\(version.id)")
      }
      Button("Remove retained version", role: .destructive) { model.requestRemoval(version) }
        .frame(minHeight: 44).disabled(
          model.isBusy || model.protectedVersionIDs.contains(version.id)
        ).accessibilityIdentifier(
          "sourceRecoveryRemove\(version.id)")
      if model.protectedVersionIDs.contains(version.id) {
        Text("Protected by pending work or a recovery draft").font(.caption)
          .accessibilityIdentifier("sourceRecoveryProtected\(version.id)")
      }
    }.accessibilityIdentifier("sourceRecoveryVersion\(version.id)")
  }

  private func draftRow(_ draft: NativeAnnotationRecoveryDraft) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(draft.operation.payload?.text ?? draft.item?.text ?? "Retained annotation").lineLimit(4)
      Text(
        draft.reason == "source_deleted"
          ? "The annotation's source was deleted" : "The annotation's source changed"
      )
      .font(.caption)
      if let reattachDraft {
        Button("Attach as new annotation") { reattachDraft(draft) }.frame(minHeight: 44)
          .disabled(model.isBusy).accessibilityIdentifier("sourceRecoveryRepair\(draft.id)")
      } else {
        Text(
          "Open this draft in Annotation Hub to choose a current edition and attach it explicitly."
        ).font(.caption)
      }
    }.accessibilityIdentifier("sourceRecoveryDraft\(draft.id)")
  }
}
