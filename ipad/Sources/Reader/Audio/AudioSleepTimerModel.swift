import Foundation
import Observation

enum AudioSleepTimerSelection: Hashable {
  case off
  case minutes(Int)
  case chapterEnd
}

@MainActor @Observable
final class AudioSleepTimerModel {
  private(set) var selection = AudioSleepTimerSelection.off
  private(set) var remainingSeconds = 0
  private(set) var chapterTitle: String?
  @ObservationIgnored private var deadline: ContinuousClock.Instant?
  @ObservationIgnored private var chapter: AudiobookManifestChapter?
  @ObservationIgnored private var assetStarts: [String: Int] = [:]

  var isActive: Bool { selection != .off }
  var canExtend: Bool { deadline != nil && remainingSeconds > 0 }

  var status: String {
    if selection == .chapterEnd {
      return chapterTitle.map { "Sleep at the end of \($0)" } ?? "Sleep at chapter end"
    }
    guard isActive else { return "Sleep timer off" }
    return "Sleep in \(AudioPlaybackModel.clock(Double(remainingSeconds)))"
  }

  func start(minutes: Int) {
    guard [1, 15, 30, 45, 60].contains(minutes) else { return }
    cancel()
    selection = .minutes(minutes)
    deadline = ContinuousClock().now.advanced(by: .seconds(minutes * 60))
    remainingSeconds = minutes * 60
  }

  func startChapterEnd(
    manifest: AudiobookManifest?, assetID: String?, positionSeconds: Double
  ) {
    guard let manifest, let assetID, positionSeconds.isFinite, positionSeconds >= 0,
      manifest.assets.allSatisfy({ ($0.durationMs ?? 0) > 0 })
    else {
      start(minutes: 30)
      return
    }
    var starts: [String: Int] = [:]
    var offset = 0
    for asset in manifest.assets {
      starts[asset.assetId] = offset
      offset += asset.durationMs ?? 0
    }
    guard let assetStart = starts[assetID] else {
      start(minutes: 30)
      return
    }
    let position = Double(assetStart) + positionSeconds * 1000
    guard let current = manifest.chapters.last(where: { Double($0.startMs) <= position }),
      Double(current.endMs) > position
    else {
      start(minutes: 30)
      return
    }
    cancel()
    chapter = current
    chapterTitle = current.title.isEmpty ? nil : current.title
    assetStarts = starts
    selection = .chapterEnd
  }

  @discardableResult
  func refreshCountdown() -> Bool {
    guard let deadline else { return false }
    let duration = ContinuousClock().now.duration(to: deadline).components
    let seconds = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
    let remaining = max(0, Int(ceil(seconds)))
    if remainingSeconds != remaining { remainingSeconds = remaining }
    return seconds <= 0
  }

  @discardableResult
  func extend() -> Bool {
    guard let deadline, !refreshCountdown() else { return false }
    self.deadline = deadline.advanced(by: .seconds(15 * 60))
    refreshCountdown()
    return true
  }

  func reachedChapterEnd(assetID: String?, positionSeconds: Double, isPlaying: Bool) -> Bool {
    guard isPlaying, let chapter, let assetID, let start = assetStarts[assetID],
      positionSeconds.isFinite, positionSeconds >= 0
    else { return false }
    let position = Double(start) + positionSeconds * 1000
    return position < Double(chapter.startMs) || position >= Double(chapter.endMs)
  }

  func cancel() {
    deadline = nil
    chapter = nil
    chapterTitle = nil
    assetStarts = [:]
    remainingSeconds = 0
    selection = .off
  }
}
