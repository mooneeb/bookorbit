import SwiftUI

struct LibraryScreen: View {
    @Bindable var library: LibraryModel
    var body: some View {
        NavigationStack {
            Group {
                if library.scope != nil {
                    List {
                        Section {
                            Stepper("Download budget: \(library.budgetGiB) GiB", value: $library.budgetGiB, in: 1...1000)
                                .onChange(of: library.budgetGiB) { Task { await library.updateBudget() } }
                            if library.measuringStorage { ProgressView("Measuring download storage") }
                            else { Text("Download storage: \(ByteCountFormatter.string(fromByteCount: library.usageBytes, countStyle: .file))") }
                            Button("Refresh storage usage") { Task { await library.refreshStorage() } }.disabled(library.measuringStorage)
                            Toggle("Downloaded books only", isOn: $library.downloadsOnly)
                                .disabled(library.transport == nil)
                                .onChange(of: library.downloadsOnly) { Task { await library.load(page: 0) } }
                            TextField("Search books", text: $library.query)
                                .submitLabel(.search)
                                .onSubmit { Task { await library.load(page: 0) } }
                            Button("Search") { Task { await library.load(page: 0) } }
                                .disabled(library.busy)
                        }
                        ForEach(library.books) { book in
                            NavigationLink(book.title ?? "Untitled book") { BookScreen(book: book, library: library) }
                        }
                        Section {
                            Button("Previous library page") { Task { await library.load(page: library.page - 1) } }
                                .disabled(library.page == 0 || library.busy)
                            Text("Library page \(library.page + 1)")
                            Button("Next library page") { Task { await library.load(page: library.page + 1) } }
                                .disabled(library.books.count < 50 || library.busy)
                        }
                    }
                    .toolbar {
                        if library.transport == nil { Button("Reconnect") { Task { await library.reconnect() } }.disabled(library.busy) }
                        Button("Sign out") { Task { await library.signOut() } }
                    }
                } else {
                    Form {
                        TextField("HTTPS server", text: $library.server).textInputAutocapitalization(.never).keyboardType(.URL)
                        TextField("Username", text: $library.username).textContentType(.username).textInputAutocapitalization(.never)
                        SecureField("Password", text: $library.password).textContentType(.password)
                        Button("Connect") { Task { await library.connect() } }.disabled(library.busy)
                        Text("Download a chosen EPUB to read offline. Notes and synchronization are unavailable in this version.")
                    }
                }
                if library.busy { ProgressView("Connecting to BookOrbit") }
                if let error = library.error { Text(error).foregroundStyle(.red).padding().accessibilityAddTraits(.updatesFrequently) }
            }
            .navigationTitle("BookOrbit")
        }
        .id(library.scope?.key ?? "disconnected")
    }
}

struct BookScreen: View {
    let book: Book
    let library: LibraryModel
    @State private var detail: Book?
    @State private var publication: LocalPublication?
    @State private var available = false
    @State private var completed: Int64 = 0
    @State private var total: Int64 = 0
    @State private var busy = false
    @State private var visible = true
    @State private var opening: Task<Void, Never>?
    @State private var error: String?

    var body: some View {
        List {
            Text(book.title ?? "Untitled book").font(.title).accessibilityAddTraits(.isHeader)
            if available {
                Text("Book ready offline")
                Button("Read downloaded EPUB") { opening = Task { await read() } }.disabled(busy)
            }
            if let detail {
                if let authors = detail.authors, !authors.isEmpty { Text(authors.joined(separator: ", ")) }
                if let publisher = detail.publisher { LabeledContent("Publisher", value: publisher) }
                if let language = detail.language { LabeledContent("Language", value: language) }
                ForEach(detail.files) { file in
                    if file.format == "epub", file.role == "content" || file.role == "primary" {
                        if !available && (library.account?.isSuperuser == true || library.account?.permissions.contains("library_download") == true) {
                            Button("Download EPUB") { opening = Task { await download(file) } }.disabled(busy || library.transport == nil)
                        }
                    } else { Text("\(file.format?.uppercased() ?? "Unknown format"): native reading unavailable") }
                }
            }
            Text("Notes, synchronization and saved reading position are unavailable in this version.")
            if busy {
                ProgressView(value: Double(completed), total: Double(max(total, 1))) { Text("Downloading and verifying EPUB") }
                Button("Cancel download") { opening?.cancel() }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle("Book details")
        .onAppear { visible = true }
        .onDisappear { visible = false; opening?.cancel() }
        .task {
            do {
                if let store = library.store { available = (try? await store.open(book: book.id)) != nil }
                if let api = library.transport { detail = try await api.detail(book.id) }
                else { detail = book }
            } catch { self.error = error.localizedDescription }
        }
        .fullScreenCover(item: $publication) { publication in
            ReaderScreen(local: publication)
        }
    }

    private func download(_ file: BookFile) async {
        guard let store = library.store, let api = library.transport else { return }
        busy = true
        defer { busy = false }
        do {
            try await store.download(book: detail ?? book, file: file.id, api: api) { count, size in
                Task { @MainActor in completed = count; total = size }
            }
            available = true
            Task { await library.refreshStorage() }
            error = nil
        }
        catch { self.error = error.localizedDescription }
    }

    private func read() async {
        do {
            guard let store = library.store else { return }
            let local = try await store.open(book: book.id)
            guard visible, !Task.isCancelled else { return }
            publication = local
        } catch { available = false; self.error = error.localizedDescription }
    }
}
