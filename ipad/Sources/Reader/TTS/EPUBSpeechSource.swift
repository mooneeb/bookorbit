import Foundation

struct EPUBSpeechChunk: Sendable {
  let cfi: String
  let text: String
  let chapterIndex: Int
  let nextCFI: String?

  var isValid: Bool {
    NativeTTSPositionModel.validCFI(cfi) && chapterIndex >= 0
      && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && text.utf16.count <= NativeTTSModel.chunkLimit
      && nextCFI.map { NativeTTSPositionModel.validCFI($0) && $0 != cfi } != false
  }
}

@MainActor
protocol EPUBSpeechSource: AnyObject {
  func speechChunk(fromCFI: String?, maximumUTF16Length: Int) async throws -> EPUBSpeechChunk?
  func highlightSpeech(chunkCFI: String, utf16Range: NSRange) async throws -> TtsPosition
  func clearSpeechHighlight() async
}
