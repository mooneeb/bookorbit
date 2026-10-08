import Foundation

extension EPUBReaderModel {
  func describePosition(_ target: String) async throws -> String {
    let raw = try await publicationCommand(
      "return await window.epubPositionPreview(target)", arguments: ["target": target])
    guard let value = raw as? [String: Any], let chapter = value["chapterIndex"] as? Int,
      let text = value["text"] as? String, (0..<chapterCount).contains(chapter),
      text.utf16.count <= 240
    else { throw ConnectionError.invalidResponse }
    return text.isEmpty ? "Chapter \(chapter + 1)" : "Chapter \(chapter + 1): \(text)"
  }

  func describePositionConflict(_ position: NativeFilePositionModel) async {
    let identity = position.conflict.identity
    guard position.conflict.isBlocked else { return }
    let local = position.localTarget
    let remote = position.remoteTarget
    var localText: String?
    var remoteText: String?
    if let local { localText = try? await describePosition(local) }
    if let remote { remoteText = try? await describePosition(remote) }
    position.conflict.describe(local: localText, remote: remoteText, identity: identity)
  }
}
