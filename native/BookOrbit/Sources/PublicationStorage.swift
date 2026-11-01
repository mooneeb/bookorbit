import Foundation
import GRDB

final class PublicationLease: @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var counts: [String: Int] = [:]
    private let key: String

    init(_ url: URL) {
        key = url.resolvingSymlinksInPath().standardizedFileURL.path
        Self.lock.withLock { Self.counts[key, default: 0] += 1 }
    }

    deinit {
        Self.lock.withLock {
            let remaining = (Self.counts[key] ?? 1) - 1
            if remaining == 0 { Self.counts.removeValue(forKey: key) }
            else { Self.counts[key] = remaining }
        }
    }

    static func contains(_ url: URL) -> Bool {
        lock.withLock { counts[url.resolvingSymlinksInPath().standardizedFileURL.path, default: 0] > 0 }
    }
}

private final class StorageWalkError: @unchecked Sendable {
    private let lock = NSLock()
    private var error: Error?
    func record(_ error: Error) { lock.withLock { self.error = error } }
    func check() throws { if let error = lock.withLock({ error }) { throw error } }
}

enum PublicationStorage {
    static func usage(directory: URL, db: DatabaseQueue) async throws -> Int64 {
        let manager = FileManager.default
        let failure = StorageWalkError()
        guard let entries = manager.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsSubdirectoryDescendants], errorHandler: { _, error in failure.record(error); return false }) else {
            throw ReaderFailure.message("Download storage could not be checked.")
        }
        var batch: [URL] = []
        while let entry = try autoreleasepool(invoking: { () throws -> (URL, Bool)? in
            guard let url = entries.nextObject() as? URL else { return nil }
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let name = url.lastPathComponent
            let owned = UUID(uuidString: name) != nil || (name.hasPrefix("staging-") && UUID(uuidString: String(name.dropFirst(8))) != nil)
            return (url, owned && values.isDirectory == true && values.isSymbolicLink != true)
        }) {
            if entry.1 { batch.append(entry.0) }
            if batch.count == 100 {
                try await collect(batch, db: db)
                batch.removeAll(keepingCapacity: true)
                await Task.yield()
            }
        }
        try failure.check()
        try await collect(batch, db: db)
        guard let files = manager.enumerator(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileSizeKey],
            errorHandler: { _, error in failure.record(error); return false }) else {
            throw ReaderFailure.message("Download storage could not be measured.")
        }
        var bytes: Int64 = 0
        var count = 0
        while let size = try autoreleasepool(invoking: { () throws -> Int64? in
            guard let file = files.nextObject() as? URL else { return nil }
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileSizeKey])
            return values.isRegularFile == true && values.isSymbolicLink != true ? Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0) : 0
        }) {
            try Task.checkCancellation()
            bytes += size
            count += 1
            if count % 100 == 0 { await Task.yield() }
        }
        try failure.check()
        return bytes
    }

    private static func collect(_ candidates: [URL], db: DatabaseQueue) async throws {
        guard !candidates.isEmpty else { return }
        let names = candidates.map(\.lastPathComponent)
        let placeholders = Array(repeating: "?", count: names.count).joined(separator: ",")
        let referenced = try await db.read { db in
            Set(try String.fetchAll(db, sql: "SELECT package FROM downloads WHERE package IN (\(placeholders))", arguments: StatementArguments(names)))
        }
        for candidate in candidates where !referenced.contains(candidate.lastPathComponent) && !PublicationLease.contains(candidate) {
            try Task.checkCancellation()
            do { try FileManager.default.removeItem(at: candidate) }
            catch let error as CocoaError where error.code == .fileNoSuchFile { }
            await Task.yield()
        }
    }
}
