import CryptoKit
import Foundation

enum PDFSourceInkSource {
  static func revision(of url: URL) async throws -> String {
    try await Task.detached(priority: .userInitiated) {
      let file = try FileHandle(forReadingFrom: url)
      defer { try? file.close() }
      var digest = SHA256()
      while let data = try file.read(upToCount: 256 * 1024), !data.isEmpty {
        try Task.checkCancellation()
        digest.update(data: data)
      }
      return "sha256:" + digest.finalize().map { String(format: "%02x", $0) }.joined()
    }.value
  }
}
