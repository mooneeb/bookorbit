import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct NativeViewBackupDocument: FileDocument {
  static var readableContentTypes: [UTType] { [.json] }
  var data: Data

  init(data: Data) { self.data = data }

  init(configuration: ReadConfiguration) throws {
    guard let data = configuration.file.regularFileContents else {
      throw NativeViewBackupError.unreadableFile
    }
    guard data.count <= NativeViewBackupFile.byteLimit else { throw NativeViewBackupError.fileSize }
    self.data = data
  }

  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    guard data.count <= NativeViewBackupFile.byteLimit else { throw NativeViewBackupError.fileSize }
    return FileWrapper(regularFileWithContents: data)
  }
}

enum NativeViewBackupFile {
  static let byteLimit = 4 * 1024 * 1024

  static func read(from url: URL) async throws -> TableViewBackup {
    let task = Task.detached(priority: .userInitiated) {
      try Task.checkCancellation()
      let scoped = url.startAccessingSecurityScopedResource()
      defer { if scoped { url.stopAccessingSecurityScopedResource() } }
      let resources = try url.resourceValues(
        forKeys: [.fileSizeKey, .isDirectoryKey, .isRegularFileKey])
      guard resources.isDirectory != true, resources.isRegularFile != false else {
        throw NativeViewBackupError.unreadableFile
      }
      if let size = resources.fileSize, size > byteLimit { throw NativeViewBackupError.fileSize }
      let handle = try FileHandle(forReadingFrom: url)
      defer { try? handle.close() }
      var data = Data()
      while true {
        try Task.checkCancellation()
        let count = min(64 * 1024, byteLimit + 1 - data.count)
        guard let chunk = try handle.read(upToCount: count), !chunk.isEmpty else { break }
        data.append(chunk)
        guard data.count <= byteLimit else { throw NativeViewBackupError.fileSize }
      }
      try Task.checkCancellation()
      let backup = try NativeViewBackupValidation.decode(data)
      try Task.checkCancellation()
      return backup
    }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }
}
