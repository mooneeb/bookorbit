import Foundation

enum BookFileDownloadKind: String, Sendable {
  case original, withoutAudio

  func path(fileID: Int) -> String {
    switch self {
    case .original: "books/files/\(fileID)/download"
    case .withoutAudio: "books/files/\(fileID)/audioless-epub/download"
    }
  }
}

enum BookFileDeliveryError: LocalizedError {
  case filenameTooLong

  var errorDescription: String? {
    "The server download filename is too long to save on this device. Shorten the filename or the server download naming pattern, then retry."
  }
}

struct StagedBookFile: Sendable, Identifiable {
  let id = UUID()
  let directory: URL
  let url: URL
  let filename: String
  let size: Int64

  @discardableResult
  func remove() -> Bool {
    do {
      try FileManager.default.removeItem(at: directory)
      return true
    } catch {
      return !FileManager.default.fileExists(atPath: directory.path)
    }
  }
}

struct BookFileTransferProgress: Sendable {
  let received: Int64
  let total: Int64
}

final class BookFileDownloadStaging {
  let artifact: StagedBookFile
  private let handle: FileHandle
  private var completed = false

  init(response: HTTPURLResponse, kind: BookFileDownloadKind) throws {
    guard response.statusCode == 200, response.expectedContentLength >= 0,
      response.expectedContentLength <= 9_007_199_254_740_991,
      response.value(forHTTPHeaderField: "Content-Encoding").map({ $0 == "identity" }) ?? true,
      kind != .withoutAudio || response.mimeType == "application/epub+zip",
      let disposition = response.value(forHTTPHeaderField: "Content-Disposition"),
      let filename = Self.filename(disposition)
    else { throw ConnectionError.invalidResponse }
    guard filename.utf8.count <= 255 else { throw BookFileDeliveryError.filenameTooLong }
    let folder = FileManager.default.temporaryDirectory
    let capacity = try FileManager.default.attributesOfFileSystem(forPath: folder.path)
    guard let free = capacity[.systemFreeSize] as? NSNumber,
      response.expectedContentLength <= free.int64Value - 128 * 1024 * 1024
    else { throw ConnectionError.insufficientStorage }
    let directory = folder.appendingPathComponent(
      "bookorbit-export-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    let url = directory.appendingPathComponent(filename, isDirectory: false)
    do {
      guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
        throw ConnectionError.insufficientStorage
      }
      handle = try FileHandle(forWritingTo: url)
    } catch {
      try? FileManager.default.removeItem(at: directory)
      throw error
    }
    artifact = StagedBookFile(
      directory: directory, url: url, filename: filename, size: response.expectedContentLength)
  }

  deinit {
    try? handle.close()
    if !completed { artifact.remove() }
  }

  func write(_ data: Data) throws {
    try handle.write(contentsOf: data)
  }

  func finish() throws -> StagedBookFile {
    try handle.close()
    completed = true
    return artifact
  }

  private static func filename(_ header: String) -> String? {
    guard header.utf8.count <= 16 * 1024,
      header.split(separator: ";", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces)
        .lowercased() == "attachment"
    else { return nil }
    let star = #"(?:^|;)\s*filename\*=UTF-8''([^;]+)"#
    let plain = #"(?:^|;)\s*filename="([^"]*)""#
    func capture(_ pattern: String) -> String? {
      guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
        let match = regex.firstMatch(
          in: header, range: NSRange(header.startIndex..<header.endIndex, in: header)),
        let range = Range(match.range(at: 1), in: header)
      else { return nil }
      return String(header[range])
    }
    let name: String?
    if let encoded = capture(star) {
      name = encoded.trimmingCharacters(in: .whitespaces).removingPercentEncoding
    } else {
      name = capture(plain)
    }
    guard let name, !name.isEmpty, name != ".", name != "..",
      !name.contains("/"), !name.contains("\\"), !name.contains("\0"),
      !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else { return nil }
    return name
  }
}
