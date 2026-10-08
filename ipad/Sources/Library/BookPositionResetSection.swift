import SwiftUI

struct BookPositionResetSection: View {
  let book: BookDetail
  let canDownload: Bool
  let isDisabled: Bool
  let notice: String?
  let reset: (NativePositionResetTarget) -> Void

  var body: some View {
    Section("Your saved positions") {
      if let notice {
        Text(notice).fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("bookPositionResetNotice")
      }
      ForEach(book.files.filter { isTextFile($0) }) { file in
        Button {
          reset(.file(bookID: book.id, fileID: file.id, label: file.filename ?? "Book file"))
        } label: {
          Text("Clear reading position: \(file.filename ?? "Book file")")
            .fixedSize(horizontal: false, vertical: true).frame(minHeight: 44)
        }
        .disabled(isDisabled).accessibilityIdentifier("clearFilePosition\(file.id)")
        if NativeEbookVocabulary.mimeTypes[file.format?.lowercased() ?? ""] != nil {
          Button {
            reset(.speech(bookID: book.id, fileID: file.id, label: file.filename ?? "Book file"))
          } label: {
            Text("Clear speech position: \(file.filename ?? "Book file")")
              .fixedSize(horizontal: false, vertical: true).frame(minHeight: 44)
          }
          .disabled(isDisabled).accessibilityIdentifier("clearSpeechPosition\(file.id)")
        }
      }
      if canDownload,
        book.files.contains(where: {
          AudioStreamFormat.mimeTypes[$0.format?.lowercased() ?? ""] != nil
        })
      {
        Button("Clear audiobook position", action: resetAudio).frame(minHeight: 44)
          .disabled(isDisabled).accessibilityIdentifier("clearAudiobookPosition")
      }
    }
  }

  private func isTextFile(_ file: BookDetailFile) -> Bool {
    let format = file.format?.lowercased() ?? ""
    return NativeEbookVocabulary.mimeTypes[format] != nil
      || ["pdf", "cbz", "cbr", "cb7"].contains(format)
  }

  private func resetAudio() { reset(.audiobook(bookID: book.id, label: book.title ?? "Audiobook")) }
}
