import SwiftUI

@main
struct BookOrbitApp: App {
    @State private var library = LibraryModel()
    var body: some Scene {
        WindowGroup { LibraryScreen(library: library) }
    }
}

struct LibraryScreen: View {
    @Bindable var library: LibraryModel
    var body: some View {
        NavigationStack {
            Group {
                if let api = library.transport, library.account != nil {
                    List {
                        Section {
                            TextField("Search books", text: $library.query)
                                .submitLabel(.search)
                                .onSubmit { Task { await library.load(page: 0) } }
                            Button("Search") { Task { await library.load(page: 0) } }
                                .disabled(library.busy)
                        }
                        ForEach(library.books) { book in
                            NavigationLink(book.title ?? "Untitled book") { BookScreen(book: book, api: api) }
                        }
                        Section {
                            Button("Previous library page") { Task { await library.load(page: library.page - 1) } }
                                .disabled(library.page == 0 || library.busy)
                            Text("Library page \(library.page + 1)")
                            Button("Next library page") { Task { await library.load(page: library.page + 1) } }
                                .disabled(library.books.count < 50 || library.busy)
                        }
                    }
                    .toolbar { Button("Sign out") { Task { await library.signOut() } } }
                } else {
                    Form {
                        TextField("HTTPS server", text: $library.server).textInputAutocapitalization(.never).keyboardType(.URL)
                        TextField("Username", text: $library.username).textContentType(.username).textInputAutocapitalization(.never)
                        SecureField("Password", text: $library.password).textContentType(.password)
                        Button("Connect") { Task { await library.connect() } }.disabled(library.busy)
                        Text("Connected EPUB reading. Downloads, notes and synchronization are unavailable in this version.")
                    }
                }
                if library.busy { ProgressView("Connecting to BookOrbit") }
                if let error = library.error { Text(error).foregroundStyle(.red).padding().accessibilityAddTraits(.updatesFrequently) }
            }
            .navigationTitle("BookOrbit")
            .task { await library.restore() }
        }
    }
}

struct BookScreen: View {
    let book: Book
    let api: Transport
    @State private var detail: Book?
    @State private var publication: Publication?
    @State private var busy = false
    @State private var visible = true
    @State private var opening: Task<Void, Never>?
    @State private var error: String?

    var body: some View {
        List {
            Text(book.title ?? "Untitled book").font(.title).accessibilityAddTraits(.isHeader)
            if let detail {
                ForEach(detail.files) { file in
                    if file.format == "epub", file.role == "content" || file.role == "primary" {
                        Button("Read EPUB") { opening = Task { await open(file) } }.disabled(busy)
                    } else { Text("\(file.format?.uppercased() ?? "Unknown format"): native reading unavailable") }
                }
            }
            Text("Online only. Reading position is not saved in this version.")
            if busy { ProgressView("Preparing verified EPUB") }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle("Book details")
        .onAppear { visible = true }
        .onDisappear { visible = false; opening?.cancel() }
        .task {
            do { detail = try await api.detail(book.id) } catch { self.error = error.localizedDescription }
        }
        .fullScreenCover(item: $publication) { publication in
            ReaderScreen(publication: publication, api: api)
        }
    }

    private func open(_ file: BookFile) async {
        busy = true
        defer { busy = false }
        do {
            let opened = try await api.open(book: book.id, file: file.id)
            guard visible, !Task.isCancelled else { await api.close(opened); return }
            publication = opened
            error = nil
        }
        catch { self.error = error.localizedDescription }
    }
}
