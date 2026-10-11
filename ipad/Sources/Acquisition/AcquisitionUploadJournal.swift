import CryptoKit
import Foundation

struct AcquisitionUploadDraft: Codable, Sendable {
  let id: String
  let filename: String
  let sizeBytes: Int
  let file: String
  var sessionID: String?
  var sessionFilename: String? = nil
  var bookDockFileID: Int? = nil
}

struct AcquisitionFinalizeDraft: Codable, Sendable {
  let request: BookDockFinalizeJobRequest
  var jobID: Int? = nil
}

actor AcquisitionUploadJournal {
  private let directory: URL
  init(namespace: String) throws {
    let digest = SHA256.hash(data: Data(namespace.utf8)).map { String(format: "%02x", $0) }.joined()
    directory = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask,
      appropriateFor: nil, create: true
    ).appendingPathComponent("Acquisition/\(digest)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }
  func load() throws -> AcquisitionUploadDraft? {
    let url = directory.appendingPathComponent("pending.json")
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try JSONDecoder().decode(AcquisitionUploadDraft.self, from: Data(contentsOf: url))
  }
  func stage(_ source: URL, maximumBytes: Int) throws -> AcquisitionUploadDraft {
    guard try load() == nil else { throw AcquisitionFailure.pendingUpload }
    let accessed = source.startAccessingSecurityScopedResource()
    defer { if accessed { source.stopAccessingSecurityScopedResource() } }
    let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard size > 0, size <= maximumBytes else { throw AcquisitionFailure.fileSize }
    let id = UUID().uuidString
    let file = directory.appendingPathComponent(id)
    try FileManager.default.copyItem(at: source, to: file)
    let draft = AcquisitionUploadDraft(
      id: id, filename: source.lastPathComponent, sizeBytes: size, file: id)
    do { try save(draft) } catch {
      try? FileManager.default.removeItem(at: file)
      throw error
    }
    return draft
  }
  func save(_ draft: AcquisitionUploadDraft) throws {
    try JSONEncoder().encode(draft).write(
      to: directory.appendingPathComponent("pending.json"), options: .atomic)
  }
  func loadFinalize() throws -> AcquisitionFinalizeDraft? {
    let url = directory.appendingPathComponent("pending-import.json")
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try JSONDecoder().decode(AcquisitionFinalizeDraft.self, from: Data(contentsOf: url))
  }
  func saveFinalize(_ draft: AcquisitionFinalizeDraft) throws {
    try JSONEncoder().encode(draft).write(
      to: directory.appendingPathComponent("pending-import.json"), options: .atomic)
  }
  func clearFinalize() throws {
    let url = directory.appendingPathComponent("pending-import.json")
    if FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.removeItem(at: url)
    }
  }
  func chunk(_ draft: AcquisitionUploadDraft, offset: Int, size: Int) throws -> Data {
    guard offset >= 0, offset < draft.sizeBytes, size > 0, size <= 4 * 1024 * 1024 else {
      throw ConnectionError.invalidResponse
    }
    let handle = try FileHandle(forReadingFrom: directory.appendingPathComponent(draft.file))
    defer { try? handle.close() }
    try handle.seek(toOffset: UInt64(offset))
    let bytes = try handle.read(upToCount: min(size, draft.sizeBytes - offset)) ?? Data()
    guard !bytes.isEmpty else { throw AcquisitionFailure.missingFile }
    return bytes
  }
  func clear() throws {
    if let draft = try load() {
      try? FileManager.default.removeItem(at: directory.appendingPathComponent(draft.file))
    }
    try FileManager.default.removeItem(at: directory.appendingPathComponent("pending.json"))
  }
}

enum AcquisitionFailure: LocalizedError {
  case pendingUpload, fileSize, missingFile
  var errorDescription: String? {
    switch self {
    case .pendingUpload:
      String(localized: "Resume or discard your pending upload before selecting another file.")
    case .fileSize: String(localized: "Choose a nonempty file within the server's upload limit.")
    case .missingFile:
      String(
        localized:
          "The local upload copy is missing. Discard this upload and select the file again.")
    }
  }
}
