import CryptoKit
import Foundation

enum NativePositionResetJournals {
  static func clear(_ target: NativePositionResetTarget, namespace: String) throws {
    switch target {
    case .file(_, let fileID, _):
      UserDefaults.standard.removeObject(
        forKey: "bookorbit.epub-progress.\(namespace).file.\(fileID)")
      try remove(directory: "RecordedNarrationPositions", key: "\(namespace).file.\(fileID)")
    case .speech(_, let fileID, _):
      let key = "bookorbit.native-tts-position.\(namespace).file.\(fileID)"
      try remove(directory: "NativeSpeechPositions", key: key)
      UserDefaults.standard.removeObject(forKey: key)
    case .audiobook: break
    }
  }

  private static func remove(directory: String, key: String) throws {
    guard
      let support = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
      ).first
    else { throw ConnectionError.invalidResponse }
    let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    let url = support.appendingPathComponent(directory, isDirectory: true)
      .appendingPathComponent("\(digest).json")
    if FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.removeItem(at: url)
    }
  }
}

@MainActor
enum NativePositionResetWait {
  static func drain(_ isBusy: @MainActor () -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(60))
    try Task.checkCancellation()
    while isBusy() {
      try Task.checkCancellation()
      guard clock.now < deadline else { throw NativePositionResetError.saveStillFinishing }
      try await Task.sleep(for: .milliseconds(25))
    }
    try Task.checkCancellation()
  }
}

enum NativePositionResetError: LocalizedError {
  case saveStillFinishing

  var errorDescription: String? {
    "A reader save is still finishing. The position has not been reset. Check again when it finishes."
  }
}
