import AVFoundation
import Foundation

enum NativeSpeechEvent: Sendable {
  case started(ObjectIdentifier)
  case word(ObjectIdentifier, NSRange)
  case paused(ObjectIdentifier)
  case continued(ObjectIdentifier)
  case finished(ObjectIdentifier)
  case cancelled(ObjectIdentifier)
}

final class NativeSpeechDelegate: NSObject, AVSpeechSynthesizerDelegate {
  private let receive: @Sendable (NativeSpeechEvent) -> Void

  init(receive: @escaping @Sendable (NativeSpeechEvent) -> Void) {
    self.receive = receive
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance)
  {
    receive(.started(ObjectIdentifier(utterance)))
  }

  func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange,
    utterance: AVSpeechUtterance
  ) {
    receive(.word(ObjectIdentifier(utterance), characterRange))
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didPause utterance: AVSpeechUtterance)
  {
    receive(.paused(ObjectIdentifier(utterance)))
  }

  func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer, didContinue utterance: AVSpeechUtterance
  ) {
    receive(.continued(ObjectIdentifier(utterance)))
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance)
  {
    receive(.finished(ObjectIdentifier(utterance)))
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance)
  {
    receive(.cancelled(ObjectIdentifier(utterance)))
  }
}
