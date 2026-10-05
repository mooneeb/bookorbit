import SwiftUI

struct BookDetailView: View {
  let api: BookOrbitAPI
  let bookID: Int
  @Environment(\.dismiss) private var dismiss
  @State private var book: BookDetail?
  @State private var error: String?

  var body: some View {
    NavigationStack {
      Group {
        if let book {
          List {
            Section {
              Text(book.title ?? "Untitled book").font(.title)
              Text(book.authors.map(\.name).joined(separator: ", "))
              Text(book.libraryName).foregroundStyle(.secondary)
            }
            Section("Files") {
              ForEach(book.files) { file in
                VStack(alignment: .leading) {
                  Text(file.filename ?? "Book file")
                  Text(file.format?.uppercased() ?? "Unknown format").font(.caption)
                    .foregroundStyle(.secondary)
                }
              }
            }
          }
        } else if let error {
          ContentUnavailableView(
            "Could not open book", systemImage: "exclamationmark.triangle", description: Text(error)
          )
        } else {
          ProgressView("Loading book…")
        }
      }
      .navigationTitle("Book details")
      .toolbar { Button("Done", action: dismiss.callAsFunction) }
    }
    .task {
      do { book = try await api.send("books/\(bookID)") } catch {
        self.error = error.localizedDescription
      }
    }
  }
}
