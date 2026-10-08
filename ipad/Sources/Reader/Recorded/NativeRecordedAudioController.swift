import AVFoundation
import Foundation

@MainActor
final class NativeRecordedAudioController {
  private var player: AVPlayer?
  private var loader: AudioResourceLoader?
  private var clock: Any?
  private var generation = UUID()
  private var begin = 0.0
  private var end = 0.0
  private var ended = false
  private var ownsSession = false
  private(set) var duration = 0.0
  private(set) var isPlaying = false
  private(set) var rate = 1.0
  var receive: (@MainActor (Double, Bool, String?) -> Void)?

  var elapsed: Double {
    guard let player else { return 0 }
    let value = player.currentTime().seconds - begin
    return value.isFinite ? min(duration, max(0, value)) : 0
  }

  func prepare(
    api: BookOrbitAPI, bookID: Int, fileID: Int,
    clip: EpubMediaOverlayClip, session: UUID, offset: Double
  ) async throws {
    close()
    let operation = generation
    let loader = AudioResourceLoader(
      api: api, bookID: bookID, fileID: fileID, clip: clip,
      sessionGeneration: session)
    self.loader = loader
    let asset = AVURLAsset(url: loader.url)
    asset.resourceLoader.setDelegate(loader, queue: .main)
    let item = AVPlayerItem(asset: asset)
    let player = AVPlayer(playerItem: item)
    self.player = player
    let deadline = Date().addingTimeInterval(25)
    while item.status == .unknown {
      try Task.checkCancellation()
      guard generation == operation, Date() < deadline else {
        throw NativeRecordedError.preparation
      }
      guard try await api.authenticatedSessionGeneration() == session else {
        throw ConnectionError.expiredSession
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    guard generation == operation, item.status == .readyToPlay else {
      throw item.error ?? NativeRecordedError.preparation
    }
    let trackDuration = try await asset.load(.duration).seconds
    guard trackDuration.isFinite, trackDuration > clip.clipBeginSeconds else {
      throw NativeRecordedError.invalidClip
    }
    begin = clip.clipBeginSeconds
    end = clip.clipEndSeconds.flatMap { $0 > begin ? $0 : nil } ?? trackDuration
    guard end <= trackDuration + 0.1, end > begin else { throw NativeRecordedError.invalidClip }
    duration = end - begin
    let position = min(max(0, offset), max(0, duration - 0.01))
    let success = await player.seek(
      to: CMTime(seconds: begin + position, preferredTimescale: 1000),
      toleranceBefore: .zero, toleranceAfter: .zero)
    guard success, operation == generation else { throw NativeRecordedError.preparation }
    player.actionAtItemEnd = .pause
    item.forwardPlaybackEndTime = CMTime(seconds: end, preferredTimescale: 1000)
    clock = player.addPeriodicTimeObserver(
      forInterval: CMTime(seconds: 0.1, preferredTimescale: 1000), queue: .main
    ) {
      [weak self] _ in
      Task { @MainActor in
        guard let self, self.generation == operation, let player = self.player else { return }
        if player.currentItem?.status == .failed {
          self.pause()
          self.receive?(
            self.elapsed, false,
            player.currentItem?.error?.localizedDescription ?? "Recorded audio failed.")
          return
        }
        let finished = self.isPlaying && player.currentTime().seconds >= self.end - 0.03
        if finished && !self.ended {
          self.ended = true
          self.pause()
          self.receive?(self.duration, true, nil)
        } else if !finished {
          self.receive?(self.elapsed, false, nil)
        }
      }
    }
  }

  func play() throws {
    guard let player, player.currentItem?.status == .readyToPlay else {
      throw NativeRecordedError.preparation
    }
    try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
    try AVAudioSession.sharedInstance().setActive(true)
    ownsSession = true
    player.playImmediately(atRate: Float(rate))
    isPlaying = true
  }

  func pause() {
    player?.pause()
    isPlaying = false
  }

  func seek(_ offset: Double) async throws {
    guard let player, offset.isFinite, (0...duration).contains(offset) else {
      throw NativeRecordedError.invalidSeek
    }
    let operation = generation
    let success = await player.seek(
      to: CMTime(seconds: begin + offset, preferredTimescale: 1000),
      toleranceBefore: .zero, toleranceAfter: .zero)
    guard success, generation == operation else { throw NativeRecordedError.invalidSeek }
    ended = false
  }

  func setRate(_ value: Double) {
    guard value.isFinite, (0.5...4).contains(value) else { return }
    rate = value
    if isPlaying { player?.rate = Float(value) }
  }

  func close() {
    generation = UUID()
    pause()
    if let clock, let player { player.removeTimeObserver(clock) }
    clock = nil
    player?.replaceCurrentItem(with: nil)
    player = nil
    loader?.close()
    loader = nil
    ended = false
    duration = 0
  }

  func releaseAudioSession() {
    guard ownsSession else { return }
    ownsSession = false
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }
}

enum NativeRecordedError: LocalizedError {
  case unavailable, invalidClip, preparation, invalidSeek, closed
  var errorDescription: String? {
    switch self {
    case .unavailable: "This passage has no publisher recorded narration."
    case .invalidClip: "The publisher audio timing does not match the delivered audio."
    case .preparation: "Recorded audio could not load. Check the connection and retry."
    case .invalidSeek: "Enter a time within the current recorded segment."
    case .closed: "Reopen the ebook to use recorded Read Along."
    }
  }
}
