import SwiftUI
import UniformTypeIdentifiers

struct NativeViewBackupView: View {
  @State private var model: NativeViewBackupModel
  @State private var showingImporter = false
  @State private var showingExporter = false
  @State private var exportDocument: NativeViewBackupDocument?
  @State private var exportCounts = NativeViewBackupCounts(presets: 0, savedViews: 0)
  @Environment(\.dismiss) private var dismiss

  init(presets: TablePresetModel, savedViews: SavedViewModel, location: BookLocation) {
    _model = State(
      initialValue: NativeViewBackupModel(
        presets: presets, savedViews: savedViews, location: location))
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        List {
          Section("Backup for \(model.location.title)") {
            Text("\(model.counts.description) at this library location.")
              .accessibilityIdentifier("viewBackupCounts")
            Text("Backups include custom column presets and saved views for this location.")
            if model.counts.isEmpty {
              Text("There is nothing saved here yet. You can export an empty backup or import one.")
                .accessibilityIdentifier("viewBackupEmpty")
            }
            Button("Export backup", action: prepareExport)
              .frame(minHeight: 44)
              .accessibilityIdentifier("exportViewBackup")
              .disabled(isBusy)
          }
          Section("Import backup") {
            Text(
              "Choose a version 1 JSON backup from BookOrbit. Imported entries are added with new IDs to this server, account, and location."
            )
            Text(
              "Both catalogs are checked before saving. For this server and account, each catalog can store up to 100 entries and 1 MiB. Files must be no larger than 4 MiB."
            )
            Button("Import backup", action: openImporter)
              .frame(minHeight: 44)
              .accessibilityIdentifier("importViewBackup")
              .disabled(isBusy)
          }
          if model.isImporting {
            Section {
              ProgressView("Importing backup…")
                .accessibilityIdentifier("viewBackupProgress")
              Button("Cancel import", action: model.cancelImport).frame(minHeight: 44)
                .accessibilityIdentifier("cancelViewBackupImport")
            }
          }
          if let status = model.status {
            Section {
              Text(status).accessibilityIdentifier("viewBackupStatus")
            }
          }
          if let error = model.error {
            Section("Could not complete backup") {
              Text(error).accessibilityIdentifier("viewBackupError")
            }
          }
        }
        .font(.body)
        .buttonStyle(.plain)
        .foregroundStyle(Color(uiColor: .label))
        Button("Done", action: dismiss.callAsFunction).font(.body).buttonStyle(.plain)
          .foregroundStyle(Color(uiColor: .label)).frame(minHeight: 44).padding()
          .disabled(isBusy)
      }
      .navigationTitle("View backup")
      .interactiveDismissDisabled(isBusy)
      .fileImporter(
        isPresented: $showingImporter, allowedContentTypes: [.json], allowsMultipleSelection: false,
        onCompletion: model.importerFinished, onCancellation: model.pickerCanceled
      )
      .fileExporter(
        isPresented: $showingExporter, document: exportDocument, contentTypes: [.json],
        defaultFilename: model.filename, onCompletion: exportFinished,
        onCancellation: exportCanceled)
    }
    .onDisappear(perform: model.cancelImport)
  }

  private var isBusy: Bool { model.isImporting || showingImporter || showingExporter }

  private func openImporter() { showingImporter = true }

  private func prepareExport() {
    do {
      let prepared = try model.prepareExport()
      exportDocument = prepared.document
      exportCounts = prepared.counts
      showingExporter = true
    } catch { model.reportExportFailure(error) }
  }

  private func exportFinished(_ result: Result<URL, any Error>) {
    model.exportFinished(result, counts: exportCounts)
    exportDocument = nil
  }

  private func exportCanceled() {
    model.exportCanceled()
    exportDocument = nil
  }
}
