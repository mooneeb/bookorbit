import Foundation

@MainActor
enum KOReaderPluginArtifact {
  static func stage(_ data: Data) throws -> StagedBookFile {
    guard !data.isEmpty, data.count <= 16 * 1024 * 1024,
      data.starts(with: [0x50, 0x4b, 0x03, 0x04])
    else { throw ConnectionError.invalidResponse }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "bookorbit-koreader-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700, .protectionKey: FileProtectionType.complete])
    do {
      let url = directory.appendingPathComponent("bookorbit.koplugin.zip")
      try data.write(to: url, options: [.atomic, .completeFileProtection])
      return StagedBookFile(
        directory: directory, url: url, filename: "bookorbit.koplugin.zip", size: Int64(data.count))
    } catch {
      try? FileManager.default.removeItem(at: directory)
      throw error
    }
  }
}
