import AVFoundation
import Foundation

enum NativeTTSAudioEvent: Sendable {
  case finished, failed
}

private final class NativeTTSAudioDelegate: NSObject, AVAudioPlayerDelegate {
  private let receive: @Sendable (NativeTTSAudioEvent) -> Void

  init(receive: @escaping @Sendable (NativeTTSAudioEvent) -> Void) { self.receive = receive }

  func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
    receive(flag ? .finished : .failed)
  }

  func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
    receive(.failed)
  }
}

@MainActor
final class NativeTTSAudioController {
  struct Caption {
    let range: NSRange
    let start: Double
    let end: Double
  }

  private var player: AVAudioPlayer?
  private var delegate: NativeTTSAudioDelegate?
  private(set) var captions: [Caption] = []
  var elapsed: Double { player?.currentTime ?? 0 }
  var isPrepared: Bool { player != nil }
  var hasWordTimings: Bool { !captions.isEmpty }

  func prepare(
    audio: Data, words: [TtsWordTiming], text: String,
    receive: @escaping @Sendable (NativeTTSAudioEvent) -> Void
  ) throws {
    stop()
    guard !audio.isEmpty, audio.count <= 8 * 1024 * 1024 else {
      throw ConnectionError.responseTooLarge
    }
    let value = try AVAudioPlayer(data: audio)
    guard value.duration.isFinite, value.duration > 0, value.duration <= 1800,
      value.prepareToPlay()
    else { throw ConnectionError.invalidResponse }
    let handler = NativeTTSAudioDelegate(receive: receive)
    value.delegate = handler
    delegate = handler
    captions = Self.mapCaptions(words, text: text, duration: value.duration)
    player = value
  }

  func play() throws {
    guard player?.play() == true else { throw NativeTTSError.serverAudioFailed }
  }

  func pause() { player?.pause() }

  func stop() {
    player?.delegate = nil
    player?.stop()
    player = nil
    delegate = nil
    captions = []
  }

  func wordRange(at time: Double) -> NSRange? {
    // Captions refer to the delivered audio clock. Pauses and synthesis latency do not advance it.
    var lower = 0
    var upper = captions.count
    while lower < upper {
      let middle = (lower + upper) / 2
      if captions[middle].start <= time { lower = middle + 1 } else { upper = middle }
    }
    guard lower > 0, time < captions[lower - 1].end else { return nil }
    return captions[lower - 1].range
  }

  private static func mapCaptions(
    _ words: [TtsWordTiming], text: String, duration: Double
  ) -> [Caption] {
    guard !words.isEmpty, words.count <= 4096 else { return [] }
    let original = text as NSString
    var cursor = 0
    var previousStart = 0.0
    var result: [Caption] = []
    for word in words {
      guard !word.word.isEmpty, word.word.utf16.count <= 512,
        word.startTime.isFinite, word.endTime.isFinite, word.startTime >= previousStart,
        word.startTime >= 0, word.endTime > word.startTime, word.endTime <= duration + 0.25
      else { return [] }
      let range = original.range(
        of: word.word, options: [],
        range: NSRange(location: cursor, length: original.length - cursor))
      guard range.location != NSNotFound, Range(range, in: text) != nil else { return [] }
      let skipped = original.substring(
        with: NSRange(location: cursor, length: range.location - cursor))
      guard
        skipped.unicodeScalars.allSatisfy({
          CharacterSet.whitespacesAndNewlines.contains($0)
            || CharacterSet.punctuationCharacters.contains($0)
        })
      else { return [] }
      result.append(Caption(range: range, start: word.startTime, end: word.endTime))
      cursor = NSMaxRange(range)
      previousStart = word.startTime
    }
    return result
  }
}
