import AVFoundation
import Foundation
import MediaPlayer

@MainActor
final class AudioMediaController {
  enum Command: Sendable {
    case play, pause, toggle
    case seek(Double)
    case skip(Double)
    case interruptionBegan
    case interruptionEnded(Bool)
    case routeRemoved
  }

  private static weak var owner: AudioMediaController?
  private let receive: (Command) -> Void
  private var targets: [(MPRemoteCommand, Any)] = []
  private var observers: [NSObjectProtocol] = []
  private var isClosed = false

  init(receive: @escaping (Command) -> Void) {
    self.receive = receive
    Self.owner?.close()
    Self.owner = self
    let center = MPRemoteCommandCenter.shared()
    install(center.playCommand, command: .play)
    install(center.pauseCommand, command: .pause)
    install(center.togglePlayPauseCommand, command: .toggle)
    install(center.skipBackwardCommand) { event in
      guard let event = event as? MPSkipIntervalCommandEvent else { return nil }
      return .skip(-event.interval)
    }
    install(center.skipForwardCommand) { event in
      guard let event = event as? MPSkipIntervalCommandEvent else { return nil }
      return .skip(event.interval)
    }
    install(center.changePlaybackPositionCommand) { event in
      guard let event = event as? MPChangePlaybackPositionCommandEvent,
        event.positionTime.isFinite, event.positionTime >= 0
      else { return nil }
      return .seek(event.positionTime)
    }
    observers.append(
      NotificationCenter.default.addObserver(
        forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
      ) { [weak self] notification in
        let type = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?
          .uintValue
        let options =
          (notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? NSNumber)?.uintValue ?? 0
        let command: Command?
        switch type {
        case AVAudioSession.InterruptionType.began.rawValue: command = .interruptionBegan
        case AVAudioSession.InterruptionType.ended.rawValue:
          command = .interruptionEnded(
            AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume))
        default: command = nil
        }
        guard let command else { return }
        Task { @MainActor in self?.deliver(command) }
      })
    observers.append(
      NotificationCenter.default.addObserver(
        forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
      ) { [weak self] notification in
        let reason = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?
          .uintValue
        guard reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else {
          return
        }
        Task { @MainActor in self?.deliver(.routeRemoved) }
      })
  }

  func update(
    title: String, authors: [String], track: Int, trackCount: Int,
    position: Double, duration: Double, rate: Double, canControl: Bool, canPause: Bool,
    skipBack: Double, skipForward: Double
  ) {
    guard !isClosed, Self.owner === self else { return }
    MPNowPlayingInfoCenter.default().nowPlayingInfo = [
      MPMediaItemPropertyTitle: title,
      MPMediaItemPropertyArtist: authors.joined(separator: ", "),
      MPMediaItemPropertyAlbumTrackNumber: track + 1,
      MPMediaItemPropertyAlbumTrackCount: trackCount,
      MPMediaItemPropertyPlaybackDuration: duration,
      MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
      MPNowPlayingInfoPropertyPlaybackRate: rate,
      MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
      MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
    ]
    let center = MPRemoteCommandCenter.shared()
    for (command, _) in targets { command.isEnabled = canControl }
    center.pauseCommand.isEnabled = canPause
    center.togglePlayPauseCommand.isEnabled = canControl || canPause
    center.skipBackwardCommand.isEnabled = canControl && skipBack > 0
    center.skipForwardCommand.isEnabled = canControl && skipForward > 0
    center.skipBackwardCommand.preferredIntervals = [NSNumber(value: skipBack)]
    center.skipForwardCommand.preferredIntervals = [NSNumber(value: skipForward)]
  }

  func close() {
    guard !isClosed else { return }
    isClosed = true
    for (command, target) in targets { command.removeTarget(target) }
    targets.removeAll()
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers.removeAll()
    if Self.owner === self {
      MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
      Self.owner = nil
    }
  }

  private func install(_ command: MPRemoteCommand, command value: Command) {
    install(command) { _ in value }
  }

  private func install(
    _ command: MPRemoteCommand,
    resolve: @escaping @Sendable (MPRemoteCommandEvent) -> Command?
  ) {
    let target = command.addTarget { [weak self] event in
      guard let value = resolve(event) else { return .commandFailed }
      Task { @MainActor in self?.deliver(value) }
      return .success
    }
    targets.append((command, target))
    command.isEnabled = false
  }

  private func deliver(_ command: Command) {
    guard !isClosed, Self.owner === self else { return }
    receive(command)
  }
}
