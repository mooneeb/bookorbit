import SwiftUI

struct CatalogBookSection: View {
  let model: CatalogSettingsModel

  var body: some View {
    Section("Selected book") {
      Text(model.book?.title ?? "Untitled").font(.headline)
      if model.files.isEmpty { Text("No content file is available for catalog delivery.") }
      ForEach(model.files) { file in
        CatalogBookFileRow(model: model, file: file)
      }
      Text(
        "Each download retrieves the current source file from the server, including published PDF ink and committed deletions. Download again after publishing changes."
      )
      .font(.footnote).foregroundStyle(.secondary)
      if model.canKOReader {
        if let progress = model.progress {
          LabeledContent("KOReader progress", value: "\(progress.canonicalPercentage.formatted())%")
          LabeledContent("Progress source", value: progress.canonicalSource)
          LabeledContent("Updated", value: progress.canonicalUpdatedAt)
          if progress.fileModifiedSinceLastSync {
            Text("The source file changed since the last sync. Redownload it on the device.")
          }
          ForEach(progress.devices, id: \.deviceId) { device in
            LabeledContent(device.device, value: "\(device.percentage.formatted())%")
          }
        } else {
          Text("No KOReader progress reported for this book.")
        }
        Text(
          "The BookOrbit KOReader plugin exchanges supported progress, bookmarks and text annotations. Private handwriting and source PDF ink remain in their original formats."
        )
        .font(.footnote).foregroundStyle(.secondary)
      }
    }
  }
}

private struct CatalogBookFileRow: View {
  let model: CatalogSettingsModel
  let file: BookDetailFile
  @State private var opdsURL: URL?
  @State private var koreaderURL: URL?

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(file.filename ?? file.format?.uppercased() ?? "Content file").font(.headline)
      if model.canOPDS, let opdsURL {
        CatalogURLRow(title: "OPDS file", url: opdsURL)
      }
      if model.canKOReader, let koreaderURL {
        CatalogURLRow(title: "KOReader file", url: koreaderURL)
      }
      if file.format?.lowercased() == "epub", file.mediaOverlay?.available == true {
        Text("Catalog readers receive the EPUB without embedded audio.")
          .font(.footnote).foregroundStyle(.secondary)
      }
    }
    .accessibilityIdentifier("catalogBookFile\(file.id)")
    .task(id: file.id) {
      opdsURL = await model.fileURL(file, opds: true)
      koreaderURL = await model.fileURL(file, opds: false)
    }
  }
}
