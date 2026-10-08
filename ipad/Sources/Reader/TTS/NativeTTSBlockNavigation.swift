import Foundation
import Observation

enum NativeTTSBlockDirection: Sendable, Equatable {
  case previous, next
}

struct NativeTTSBlockRequest: Sendable {
  let direction: NativeTTSBlockDirection
  let chunk: EPUBSpeechChunk
}

@MainActor @Observable
final class NativeTTSBlockNavigation {
  private(set) var isLoading = false
  private(set) var error: String?
  private(set) var boundaryMessage: String?
  private(set) var request: NativeTTSBlockRequest?
  private(set) var resolvedChunk: EPUBSpeechChunk?
  @ObservationIgnored private var current: EPUBSpeechChunk?
  @ObservationIgnored private var previous: [EPUBSpeechChunk] = []

  var canRetry: Bool { error != nil && request != nil }

  func begin(_ request: NativeTTSBlockRequest, resolved: EPUBSpeechChunk? = nil) {
    self.request = request
    resolvedChunk = resolved
    isLoading = true
    error = nil
    boundaryMessage = nil
  }

  func resolve(_ chunk: EPUBSpeechChunk) { resolvedChunk = chunk }

  func remember(_ chunk: EPUBSpeechChunk) {
    guard current?.cfi != chunk.cfi else { return }
    if let current, current.chapterIndex == chunk.chapterIndex {
      if request?.direction == .previous, previous.last?.cfi == chunk.cfi {
        previous.removeLast()
      } else if request?.direction == .previous {
        previous.removeAll(keepingCapacity: true)
      } else {
        previous.append(current)
        if previous.count > 32 { previous.removeFirst(previous.count - 32) }
      }
    } else {
      previous.removeAll(keepingCapacity: true)
    }
    current = chunk
  }

  func previousChunk(from chunk: EPUBSpeechChunk) -> EPUBSpeechChunk? {
    guard current?.cfi == chunk.cfi else { return nil }
    return previous.last
  }

  func completed(atBeginning: Bool = false) {
    isLoading = false
    error = nil
    boundaryMessage = atBeginning ? "Beginning of this speech section." : nil
  }

  func failed(_ error: any Error) {
    guard request != nil else { return }
    isLoading = false
    self.error = error.localizedDescription
  }

  func clearRequest() {
    isLoading = false
    error = nil
    boundaryMessage = nil
    request = nil
    resolvedChunk = nil
  }

  func reset() {
    clearRequest()
    current = nil
    previous.removeAll(keepingCapacity: false)
  }
}
