import Foundation

@MainActor
final class NativeReadingRecordJournal {
  private let file: URL

  init(namespace: String, key: String) throws {
    let root = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
    ).appendingPathComponent("BookOrbitReadingRecords", isDirectory: true)
      .appendingPathComponent(OfflineResourceStore.hash(Data(namespace.utf8)), isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    file = root.appendingPathComponent(OfflineResourceStore.hash(Data(key.utf8)) + ".json")
  }

  func read<T: Decodable>(_ type: T.Type) throws -> T? {
    guard FileManager.default.fileExists(atPath: file.path) else { return nil }
    guard let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
      size <= 2 * 1024 * 1024
    else { throw ConnectionError.responseTooLarge }
    return try JSONDecoder().decode(type, from: Data(contentsOf: file))
  }

  func save<T: Encodable>(_ value: T) throws {
    let data = try JSONEncoder().encode(value)
    guard data.count <= 2 * 1024 * 1024 else { throw OfflineStorageError.storageLimit }
    try data.write(
      to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
  }
}
