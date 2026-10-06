import SwiftUI

@main
struct ReaderProofApp: App {
  @State private var session = SessionModel()
  @Environment(\.scenePhase) private var scenePhase

  var body: some Scene {
    WindowGroup {
      Group {
        if session.user?.isDefaultPassword == true {
          ChangePasswordView(session: session)
        } else if session.user != nil, let api = session.api {
          ReaderProofLibraryView(session: session, api: api)
        } else {
          ConnectionView(session: session)
        }
      }
      .task { await session.restore() }
      .onChange(of: scenePhase) {
        if scenePhase == .active { Task { await session.returnToForeground() } }
      }
    }
  }
}

private struct ReaderProofLibraryView: View {
  let session: SessionModel
  @State private var library: LibraryModel
  @State private var selectedBook: BookCard?

  init(session: SessionModel, api: BookOrbitAPI) {
    self.session = session
    _library = State(initialValue: LibraryModel(api: api))
  }

  var body: some View {
    NavigationStack {
      List {
        Text(library.total == 1 ? "1 book" : "\(library.total.formatted()) books")
        ForEach(library.books) { book in
          Button(book.title ?? "Untitled book") { selectedBook = book }
        }
        if library.isBusy { ProgressView("Loading books…") }
        if let error = library.error { Text(error) }
      }
      .navigationTitle("Reader proof")
      .searchable(text: $library.search, prompt: "Search books")
      .onSubmit(of: .search) { Task { await library.searchBooks() } }
      .toolbar {
        Button("Sign out") { Task { await session.signOut() } }
          .accessibilityIdentifier("signOut")
      }
    }
    .task { await library.load() }
    .sheet(item: $selectedBook) { book in
      ReaderProofBookView(api: library.api, bookID: book.id)
    }
  }
}

private struct ReaderProofBookView: View {
  @State private var model: BookDetailModel
  @State private var selectedFile: BookDetailFile?
  @State private var nativeChapterFile: BookDetailFile?
  @Environment(\.dismiss) private var dismiss

  init(api: BookOrbitAPI, bookID: Int) {
    _model = State(initialValue: BookDetailModel(api: api, bookID: bookID))
  }

  var body: some View {
    NavigationStack {
      List {
        if let book = model.book {
          Text(book.title ?? "Untitled book").font(.title)
          ForEach(book.files) { file in
            VStack(alignment: .leading) {
              Text(file.filename ?? "Book file")
              if ["pdf", "epub", "cbz"].contains(file.format?.lowercased() ?? "") {
                Button("Read") { selectedFile = file }
                  .accessibilityIdentifier("readFile\(file.id)")
              }
              if file.format?.lowercased() == "epub" {
                Button("Inspect native chapter") { nativeChapterFile = file }
                  .accessibilityIdentifier("inspectNativeFile\(file.id)")
              }
            }
            .buttonStyle(.borderless)
          }
        } else if let error = model.error {
          Text(error)
        } else {
          ProgressView("Loading book…")
        }
      }
      .navigationTitle("Book details")
      .toolbar { Button("Done", action: dismiss.callAsFunction) }
    }
    .task { await model.load() }
    .fullScreenCover(item: $selectedFile) { file in
      if file.format?.lowercased() == "cbz" {
        ComicProofView(api: model.api, file: file)
      } else if file.format?.lowercased() == "epub" {
        EPUBProofView(api: model.api, bookID: model.bookID, file: file)
      } else {
        PDFReaderView(api: model.api, file: file)
      }
    }
    .fullScreenCover(item: $nativeChapterFile) { file in
      NativeChapterView(api: model.api, bookID: model.bookID, file: file)
    }
  }
}
