import SwiftUI

struct BookFileRowView: View {
  let file: BookDetailFile
  let canRead: Bool
  let canManage: Bool
  let open: (BookDetailFile) -> Void
  let manage: (BookDetailFile) -> Void

  private var isReadable: Bool {
    let format = file.format?.lowercased() ?? ""
    return NativeEbookVocabulary.mimeTypes[format] != nil
      || ["pdf", "cbz", "cbr", "cb7"].contains(format)
      || AudioStreamFormat.mimeTypes[format] != nil
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(file.filename ?? "Book file").fixedSize(horizontal: false, vertical: true)
      Text(file.format?.uppercased() ?? "Unknown format").font(.caption).foregroundStyle(.secondary)
      if canRead, isReadable {
        Button("Read", action: read).frame(minHeight: 44)
          .accessibilityIdentifier("readFile\(file.id)")
      }
      if canManage {
        Button("Manage file", action: showActions).frame(minHeight: 44)
          .accessibilityIdentifier("manageFile\(file.id)")
      }
    }
    .buttonStyle(.borderless)
  }

  private func read() { open(file) }
  private func showActions() { manage(file) }
}
