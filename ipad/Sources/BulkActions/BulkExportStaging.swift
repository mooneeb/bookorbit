import Foundation

final class BulkExportStaging {
  static let maximumBytes: Int64 = 8 * 1024 * 1024 * 1024
  private let directory: URL
  private let url: URL
  private let handle: FileHandle
  private var completed = false
  private var bytesSinceSpaceCheck = 0

  init(response: HTTPURLResponse) throws {
    guard response.statusCode == 200, response.expectedContentLength <= Self.maximumBytes,
      ["application/zip", "application/json", "text/csv"].contains(response.mimeType ?? ""),
      response.value(forHTTPHeaderField: "Content-Encoding").map({ $0 == "identity" }) ?? true
    else { throw ConnectionError.invalidResponse }
    let ext =
      response.mimeType == "application/zip"
      ? "zip" : response.mimeType == "text/csv" ? "csv" : "json"
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "bookorbit-bulk-\(UUID().uuidString)", isDirectory: true)
    url = directory.appendingPathComponent("BookOrbit-selected-books.\(ext)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    do {
      guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
        throw ConnectionError.insufficientStorage
      }
      handle = try FileHandle(forWritingTo: url)
    } catch {
      try? FileManager.default.removeItem(at: directory)
      throw error
    }
  }

  deinit {
    try? handle.close()
    if !completed { try? FileManager.default.removeItem(at: directory) }
  }

  func write(_ data: Data) throws {
    if bytesSinceSpaceCheck == 0 || bytesSinceSpaceCheck >= 8 * 1024 * 1024 {
      let attributes = try FileManager.default.attributesOfFileSystem(forPath: directory.path)
      guard let free = attributes[.systemFreeSize] as? NSNumber,
        free.int64Value > 136 * 1024 * 1024
      else { throw ConnectionError.insufficientStorage }
      bytesSinceSpaceCheck = 0
    }
    try handle.write(contentsOf: data)
    bytesSinceSpaceCheck += data.count
  }

  func finish(size: Int64) throws -> StagedBookFile {
    try handle.close()
    if url.pathExtension == "zip" {
      let reader = try FileHandle(forReadingFrom: url)
      defer { try? reader.close() }
      try reader.seek(toOffset: UInt64(max(0, size - 65_557)))
      let tail = try reader.readToEnd() ?? Data()
      let marker = Data([0x50, 0x4b, 0x05, 0x06])
      guard let range = tail.range(of: marker, options: .backwards),
        tail.count - range.lowerBound >= 22
      else { throw ConnectionError.invalidResponse }
      let offset = range.lowerBound
      let commentLength = Int(tail[offset + 20]) | (Int(tail[offset + 21]) << 8)
      guard offset + 22 + commentLength == tail.count else { throw ConnectionError.invalidResponse }
    }
    completed = true
    return StagedBookFile(
      directory: directory, url: url, filename: url.lastPathComponent, size: size)
  }
}
