import Foundation

/// The on-device home of everything that belongs to the signed-in account: offline books, the
/// outbox, caches. Features must keep account data under `directory(named:)` so that signing out
/// wipes it.
public struct AccountStorage: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public static func standard() -> AccountStorage {
        let base = URL.applicationSupportDirectory.appending(path: "BookOrbit/Account", directoryHint: .isDirectory)
        return AccountStorage(root: base)
    }

    public func directory(named name: String) throws -> URL {
        try prepareRoot()
        let url = root.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Account data can be re-downloaded from the server, and must not follow a device backup to
    /// another device where a different account may sign in.
    private func prepareRoot() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var rootURL = root
        try rootURL.setResourceValues(values)
    }

    /// Makes the storage belong to the given account, wiping whatever another account left behind
    /// (for example after a session expired and someone else signed in).
    func claim(server: ServerAddress, userId: Int) throws {
        let owner = Owner(server: server, userId: userId)
        let markerURL = root.appending(path: Self.ownerMarker)
        if let data = try? Data(contentsOf: markerURL), let existing = try? JSONDecoder().decode(Owner.self, from: data), existing == owner {
            return
        }
        try wipe()
        try prepareRoot()
        try JSONEncoder().encode(owner).write(to: markerURL, options: .atomic)
    }

    private static let ownerMarker = ".owner.json"

    private struct Owner: Codable, Equatable {
        let server: ServerAddress
        let userId: Int
    }

    func wipe() throws {
        guard FileManager.default.fileExists(atPath: root.path()) else { return }
        try FileManager.default.removeItem(at: root)
    }
}
