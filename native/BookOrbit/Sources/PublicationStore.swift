import Foundation
import CryptoKit
import GRDB
import Darwin
import ImageIO

struct LocalPublication: Sendable, Identifiable {
    var id: UUID { publication.id }
    let publication: Publication
    let book: Book
    let directory: URL
    let lease: PublicationLease?
    var original: URL { directory.appendingPathComponent("original") }

    func member(_ index: Int) async throws -> Data {
        guard publication.members.indices.contains(index) else { throw ReaderFailure.message("Unknown publication member.") }
        let member = publication.members[index]
        let path = directory.appendingPathComponent(String(index))
        return try await Task.detached {
            try PublicationFiles.verify(path, bytes: member.bytes, digest: member.sha256)
            return try Data(contentsOf: path)
        }.value
    }
}

enum PublicationFiles {
    static func verifyImage(_ url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetType(source) != nil else { return }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 8192, height <= 8192, width <= 16_000_000 / height,
              CGImageSourceGetCount(source) == 1 else { throw ReaderFailure.message("Image exceeds the static reader limits.") }
    }
    static func verify(_ url: URL, bytes: Int, digest: String) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, values.fileSize == bytes else {
            throw ReaderFailure.message("A downloaded resource is missing or has changed. Download again.")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 64 * 1024), !data.isEmpty { hash.update(data: data) }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == digest else {
            throw ReaderFailure.message("Downloaded resource verification failed. Download again.")
        }
    }

    static func flush(_ url: URL, directory: Bool = false) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY | (directory ? O_DIRECTORY : 0))
        guard descriptor >= 0 else { throw ReaderFailure.message("Downloaded files could not be saved.") }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else { throw ReaderFailure.message("Downloaded files could not be saved.") }
    }
}

actor PublicationStore {
    private let db: DatabaseQueue
    private let directory: URL
    let scope: SessionReference
    private let reserveBytes: Int64
    private var budgetBytes: Int64
    private var downloading = false
    private var storageCheck: (id: UUID, task: Task<Int64, Error>)?
    private var storageWaiters: [CheckedContinuation<Void, Never>] = []

    init(root: URL, scope: SessionReference, reserveBytes: Int64 = 1024 * 1024 * 1024, budgetBytes: Int64 = 10 * 1024 * 1024 * 1024) throws {
        self.scope = scope
        self.reserveBytes = reserveBytes
        self.budgetBytes = budgetBytes
        let key = "\(scope.origin.absoluteString)|\(scope.identity.uuidString)|\(scope.account)"
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        directory = root.appendingPathComponent(digest, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode=DELETE")
            try db.execute(sql: "PRAGMA synchronous=FULL")
            try db.execute(sql: "PRAGMA foreign_keys=ON")
        }
        db = try DatabaseQueue(path: directory.appendingPathComponent("library.sqlite").path, configuration: config)
        var migrations = DatabaseMigrator()
        migrations.registerMigration("v1-publications") { db in
            try db.create(table: "downloads") { table in
                table.column("bookId", .integer).primaryKey()
                table.column("title", .text).notNull()
                table.column("book", .blob).notNull()
                table.column("manifest", .blob).notNull()
                table.column("package", .text).notNull().unique()
                table.column("bytes", .integer).notNull()
            }
            try db.create(index: "downloads_title", on: "downloads", columns: ["title", "bookId"])
        }
        try migrations.migrate(db)
        try db.read { db in
            guard try String.fetchOne(db, sql: "PRAGMA journal_mode") == "delete",
                  try Int.fetchOne(db, sql: "PRAGMA synchronous") == 2,
                  try Int.fetchOne(db, sql: "PRAGMA foreign_keys") == 1 else {
                throw ReaderFailure.message("Local durability settings are unavailable.")
            }
        }
    }

    func books(page: Int, query: String = "") throws -> [Book] {
        guard page >= 0, page <= 1_000_000 else { throw ReaderFailure.message("Invalid local page.") }
        let search = String(query.prefix(200)).replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        return try db.read { db in
            try Data.fetchAll(db, sql: "SELECT book FROM downloads WHERE title LIKE ? ESCAPE '\\' ORDER BY title, bookId LIMIT 50 OFFSET ?",
                arguments: ["%\(search)%", page * 50]).map { try JSONDecoder().decode(Book.self, from: $0) }
        }
    }

    func setBudget(_ bytes: Int64) { budgetBytes = max(1024 * 1024 * 1024, bytes) }

    func diskBytes() async throws -> Int64 {
        while downloading { await withCheckedContinuation { storageWaiters.append($0) } }
        try Task.checkCancellation()
        return try await measureStorage()
    }

    private func measureStorage() async throws -> Int64 {
        let flight: (id: UUID, task: Task<Int64, Error>)
        if let storageCheck { flight = storageCheck }
        else {
            let directory = directory, db = db
            flight = (UUID(), Task.detached { try await PublicationStorage.usage(directory: directory, db: db) })
            storageCheck = flight
        }
        defer { if storageCheck?.id == flight.id { storageCheck = nil } }
        return try await flight.task.value
    }

    func open(book: Int) throws -> LocalPublication {
        // Acquire the lease before a concurrent database writer can retire this package.
        let record = try db.read { db -> (Row, PublicationLease)? in
            guard let row = try Row.fetchOne(db, sql: "SELECT book, manifest, package FROM downloads WHERE bookId = ?", arguments: [book]) else { return nil }
            let name: String = row["package"]
            guard UUID(uuidString: name) != nil else { throw ReaderFailure.message("Invalid local package.") }
            return (row, PublicationLease(directory.appendingPathComponent(name)))
        }
        guard let (row, lease) = record else { throw ReaderFailure.message("Choose Download to keep this book offline.") }
        let publication = try JSONDecoder().decode(Publication.self, from: row["manifest"] as Data)
        try validate(publication)
        let name: String = row["package"]
        guard UUID(uuidString: name) != nil else { throw ReaderFailure.message("Invalid local package.") }
        let local = LocalPublication(publication: publication, book: try JSONDecoder().decode(Book.self, from: row["book"] as Data),
            directory: directory.appendingPathComponent(name), lease: lease)
        try PublicationFiles.verify(local.original, bytes: publication.sourceBytes, digest: publication.sourceSha256)
        for (index, member) in publication.members.enumerated() {
            try Task.checkCancellation()
            try PublicationFiles.verify(local.directory.appendingPathComponent(String(index)), bytes: member.bytes, digest: member.sha256)
        }
        return local
    }

    func download(book: Book, file: Int, api: Transport, progress: @Sendable (Int64, Int64) -> Void = { _, _ in }) async throws {
        guard !downloading else { throw ReaderFailure.message("One book is already downloading. Wait or cancel it.") }
        downloading = true
        defer {
            downloading = false
            let waiters = storageWaiters
            storageWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
        let exists = try await db.read { try Bool.fetchOne($0, sql: "SELECT EXISTS(SELECT 1 FROM downloads WHERE bookId = ?)", arguments: [book.id]) ?? false }
        if exists, (try? open(book: book.id)) != nil { throw ReaderFailure.message("This book is already downloaded.") }
        let publication = try await api.open(book: book.id, file: file)
        do {
            try validate(publication)
            let total = Int64(publication.sourceBytes) + publication.members.reduce(Int64(0)) { $0 + Int64($1.bytes) }
            let used = try await measureStorage()
            let available = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
            guard total <= budgetBytes - used, total <= available - reserveBytes else {
                throw ReaderFailure.message("There is not enough download space. Free space or adjust the download budget.")
            }
            let staging = directory.appendingPathComponent("staging-\(UUID().uuidString)")
            let package = UUID().uuidString
            let final = directory.appendingPathComponent(package)
            // The renamed directory is briefly unreferenced until the database commit.
            let stagingLease = PublicationLease(staging), finalLease = PublicationLease(final)
            defer { withExtendedLifetime((stagingLease, finalLease)) {} }
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: staging) }
            var completed: Int64 = 0
            progress(completed, total)
            try await api.downloadFile(publication, to: staging.appendingPathComponent("original"))
            try PublicationFiles.flush(staging.appendingPathComponent("original"))
            completed += Int64(publication.sourceBytes)
            progress(completed, total)
            for (index, member) in publication.members.enumerated() {
                try Task.checkCancellation()
                let destination = staging.appendingPathComponent(String(index))
                try await api.downloadFile(publication, index: index, to: destination)
                try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: destination.path)
                try PublicationFiles.verifyImage(destination)
                try PublicationFiles.flush(destination)
                completed += Int64(member.bytes)
                progress(completed, total)
            }
            try await OfflinePackageValidator.validate(LocalPublication(publication: publication, book: book, directory: staging, lease: stagingLease))
            try PublicationFiles.flush(staging, directory: true)
            try FileManager.default.moveItem(at: staging, to: final)
            try PublicationFiles.flush(directory, directory: true)
            let encodedBook = try JSONEncoder().encode(book)
            let encodedManifest = try JSONEncoder().encode(publication)
            do {
                try Task.checkCancellation()
                try await db.write { db in
                    try db.execute(sql: "INSERT INTO downloads (bookId, title, book, manifest, package, bytes) VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(bookId) DO UPDATE SET title=excluded.title, book=excluded.book, manifest=excluded.manifest, package=excluded.package, bytes=excluded.bytes",
                        arguments: [book.id, book.title ?? "Untitled book", encodedBook, encodedManifest, package, total])
                }
            } catch { try? FileManager.default.removeItem(at: final); throw error }
            await api.close(publication)
        } catch {
            await api.close(publication)
            throw error
        }
    }

    private func validate(_ publication: Publication) throws {
        guard publication.version == 1, publication.instanceId == scope.identity, publication.accountId == scope.account,
              publication.sourceRevision == publication.sourceSha256 else {
            throw ReaderFailure.message("The package does not belong to the verified server and account.")
        }
        try publication.validateIntegrity()
    }
}
