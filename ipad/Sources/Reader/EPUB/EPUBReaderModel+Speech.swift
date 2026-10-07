import Foundation

extension EPUBReaderModel: EPUBSpeechSource {
  func speechChunk(fromCFI: String?, maximumUTF16Length: Int) async throws -> EPUBSpeechChunk? {
    guard (2...2048).contains(maximumUTF16Length),
      fromCFI.map({
        ($0.hasPrefix("epubcfi(")
          || $0.range(of: "^tts:[0-9]{1,9}:[0-9]{1,9}$", options: .regularExpression) != nil)
          && $0.utf16.count <= 2000
      }) ?? true
    else { throw ConnectionError.invalidResponse }
    try await waitForSpeechLayout()
    let startCFI = fromCFI ?? selectionCFI ?? location?.cfi
    let raw = try await publicationCommand(
      "return await window.epubSpeechChunk(cfi, maximum)",
      arguments: [
        "cfi": startCFI as Any? ?? NSNull(), "maximum": maximumUTF16Length,
      ])
    if raw == nil || raw is NSNull { return nil }
    guard let value = raw as? [String: Any], let cfi = value["cfi"] as? String,
      let text = value["text"] as? String, let chapter = value["chapterIndex"] as? Int,
      (0..<chapterCount).contains(chapter), cfi.hasPrefix("epubcfi("),
      cfi.utf16.count <= 2000,
      !text.isEmpty, text.utf16.count <= maximumUTF16Length
    else { throw ConnectionError.invalidResponse }
    let next = value["nextCFI"] as? String
    guard next.map({ $0.hasPrefix("epubcfi(") && $0.utf16.count <= 2000 }) ?? true else {
      throw ConnectionError.invalidResponse
    }
    return .init(cfi: cfi, text: text, chapterIndex: chapter, nextCFI: next)
  }
  func highlightSpeech(chunkCFI: String, utf16Range: NSRange) async throws -> TtsPosition {
    guard chunkCFI.hasPrefix("epubcfi("), chunkCFI.utf16.count <= 2000, utf16Range.location >= 0,
      utf16Range.length > 0, utf16Range.location <= 2048 - utf16Range.length
    else { throw ConnectionError.invalidResponse }
    try await waitForSpeechLayout()
    let raw = try await publicationCommand(
      "return await window.epubHighlightSpeech(cfi, offset, length)",
      arguments: [
        "cfi": chunkCFI, "offset": utf16Range.location, "length": utf16Range.length,
      ])
    let data = try JSONSerialization.data(withJSONObject: raw as Any)
    guard data.count <= 8192 else { throw ConnectionError.invalidResponse }
    let position = try JSONDecoder().decode(TtsPosition.self, from: data)
    guard position.cfi.hasPrefix("epubcfi("), position.cfi.utf16.count <= 2000,
      let chapter = position.chapterIndex, (0..<chapterCount).contains(chapter)
    else { throw ConnectionError.invalidResponse }
    return position
  }
  func clearSpeechHighlight() async {
    try? await waitForSpeechLayout()
    _ = try? await publicationCommand("window.epubClearSpeechHighlight()", arguments: [:])
  }

  private func waitForSpeechLayout() async throws {
    while isNavigating || isSearching {
      try Task.checkCancellation()
      guard isReady else { throw NativeTTSError.readerClosed }
      try await Task.sleep(for: .milliseconds(50))
    }
  }
}
