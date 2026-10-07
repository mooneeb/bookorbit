import Foundation
import Observation
import UIKit

@MainActor @Observable
final class AudioPlayerModel {
  let engine: AudioPlaybackModel
  let preferences: AudioPreferencesModel
  private(set) var isChangingTrack = false
  private(set) var isWriting = false
  private(set) var isClosing = false
  private(set) var activeSleepMinutes: Int?
  private(set) var closeWarning: String?
  @ObservationIgnored private var media: AudioMediaController?
  @ObservationIgnored private var autosave: Task<Void, Never>?
  @ObservationIgnored private var sleepTask: Task<Void, Never>?
  @ObservationIgnored private var backgroundWrite: Task<Void, Never>?
  private var wantsPlay = false
  private var resumeAfterInterruption = false
  private var isClosed = false
  private var lastMediaSecond = -1
  private var lastMediaPlaying = false
  private var lastMediaAsset: String?
  private var lastMediaCanControl = false
  private var lastMediaCanPause = false
  private var saveAfterWrite = false
  private var advanceAfterWrite = false

  init(api: BookOrbitAPI, bookID: Int, fileID: Int) {
    engine = AudioPlaybackModel(api: api, bookID: bookID, fileID: fileID)
    preferences = AudioPreferencesModel(api: api)
  }

  var canInteract: Bool {
    !isClosed && !isChangingTrack && !isWriting && !isClosing && !preferences.isSaving
      && engine.isReady && engine.canSelectTrack && !engine.progressBlocked
  }

  var canTogglePlayback: Bool {
    !isClosed && (engine.isPlaying || canInteract)
  }

  var canClose: Bool {
    !isClosed && !isChangingTrack && !isWriting && !isClosing && !preferences.isSaving
      && !engine.isSaving && !engine.isSeeking
  }

  var canSave: Bool {
    !isClosed && !isChangingTrack && !isWriting && !isClosing && engine.canSave
  }

  var hasPreviousTrack: Bool { (engine.currentAsset?.sequence ?? 0) > 0 }
  var hasNextTrack: Bool {
    guard let manifest = engine.manifest, let current = engine.currentAsset else { return false }
    return current.sequence + 1 < manifest.assets.count
  }

  var chaptersAvailable: Bool {
    engine.manifest?.assets.allSatisfy { ($0.durationMs ?? 0) > 0 } == true
  }

  func open() async {
    guard !isClosed, autosave == nil else { return }
    engine.updated = { [weak self] in self?.engineUpdated() }
    engine.ended = { [weak self] in
      Task { @MainActor in await self?.trackEnded() }
    }
    media = AudioMediaController { [weak self] command in
      Task { @MainActor in await self?.handle(command) }
    }
    await preferences.load()
    guard !isClosed, !Task.isCancelled else { return }
    engine.configure(speed: preferences.value.playbackSpeed, volume: preferences.value.volume)
    await engine.open()
    guard !isClosed, !Task.isCancelled else { return }
    refreshMedia()
    autosave = Task { [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(10)) } catch { return }
        guard let self, !self.isClosed else { return }
        guard await self.engine.checkSession() else {
          self.wantsPlay = false
          self.refreshMedia()
          return
        }
        if self.engine.isPlaying, !self.engine.hasPendingSave { await self.saveProgress() }
      }
    }
  }

  func togglePlayback() async {
    guard canTogglePlayback else { return }
    wantsPlay = false
    if engine.isPlaying {
      await pauseAndSave()
    } else {
      if engine.positionSeconds >= engine.durationSeconds - 0.05 {
        guard await engine.seek(to: 0) else { return }
      }
      engine.play()
    }
    refreshMedia()
  }

  func seek(to seconds: Double) async {
    guard canInteract else { return }
    if await engine.seek(to: seconds) { await saveProgress() }
    refreshMedia()
  }

  func skip(_ seconds: Double) async {
    guard seconds.isFinite, canInteract else { return }
    await seek(to: min(engine.durationSeconds, max(0, engine.positionSeconds + seconds)))
  }

  func previousTrack() async { await adjacentTrack(-1, autoplay: engine.isPlaying) }
  func nextTrack() async { await adjacentTrack(1, autoplay: engine.isPlaying) }

  func select(_ asset: AudiobookManifestAsset) async {
    await activate(asset, positionMs: 0, autoplay: engine.isPlaying)
  }

  func selectChapter(_ chapter: AudiobookManifestChapter) async {
    guard chaptersAvailable, let manifest = engine.manifest,
      manifest.chapters.contains(chapter),
      let asset = manifest.assets.first(where: { $0.assetId == chapter.assetId })
    else { return }
    await activate(asset, positionMs: chapter.assetOffsetMs, autoplay: engine.isPlaying)
  }

  func retryPlayback() {
    guard !isClosed, !isWriting, !isChangingTrack, !isClosing, !preferences.isSaving,
      engine.canSelectTrack
    else { return }
    wantsPlay = false
    engine.retryPlayback()
  }

  func saveProgress() async {
    guard canSave else { return }
    await persistPosition()
  }

  func reloadSettings() async {
    guard !isClosed, canClose else { return }
    await preferences.load()
    guard !isClosed else { return }
    engine.configure(speed: preferences.value.playbackSpeed, volume: preferences.value.volume)
    refreshMedia()
  }

  func saveSettings(_ value: AudioReaderSettings) async -> Bool {
    guard canClose else { return false }
    let saved = await preferences.save(value)
    if saved, !isClosed {
      engine.configure(speed: value.playbackSpeed, volume: value.volume)
      refreshMedia()
    }
    return saved
  }

  func setSleepTimer(minutes: Int) {
    guard !isClosed, [0, 1, 15, 30, 45, 60].contains(minutes) else { return }
    sleepTask?.cancel()
    sleepTask = nil
    activeSleepMinutes = minutes == 0 ? nil : minutes
    guard minutes > 0 else { return }
    sleepTask = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(minutes * 60)) } catch { return }
      guard let self, !self.isClosed else { return }
      self.activeSleepMinutes = nil
      self.wantsPlay = false
      await self.pauseAndSave()
      self.refreshMedia()
    }
  }

  func foreground() async {
    guard !isClosed else { return }
    if !(await engine.checkSession()) { wantsPlay = false }
    refreshMedia()
  }

  func background() {
    guard !isClosed, backgroundWrite == nil, canSave else { return }
    var identifier = UIBackgroundTaskIdentifier.invalid
    identifier = UIApplication.shared.beginBackgroundTask(withName: "Save audiobook position") {
      [weak self] in
      Task { @MainActor in self?.backgroundWrite?.cancel() }
    }
    backgroundWrite = Task { [weak self] in
      if let self { await self.saveProgress() }
      if identifier != .invalid { UIApplication.shared.endBackgroundTask(identifier) }
      self?.backgroundWrite = nil
    }
  }

  func finish() async -> Bool {
    guard canClose else { return false }
    isClosing = true
    closeWarning = nil
    wantsPlay = false
    engine.pause()
    let requiresSave = engine.isReady || engine.hasPendingSave || engine.positionSeconds > 0
    let saved = requiresSave ? await persistPosition() : true
    isClosing = false
    if saved {
      close()
      return true
    }
    closeWarning =
      engine.progressMessage ?? "Your latest listening position could not be confirmed."
    refreshMedia()
    return false
  }

  func close() {
    guard !isClosed else { return }
    isClosed = true
    wantsPlay = false
    autosave?.cancel()
    autosave = nil
    sleepTask?.cancel()
    sleepTask = nil
    backgroundWrite?.cancel()
    backgroundWrite = nil
    media?.close()
    media = nil
    preferences.close()
    engine.close()
  }

  @discardableResult
  private func persistPosition() async -> Bool {
    guard engine.canSave, !isClosed, !isWriting else { return false }
    isWriting = true
    refreshMedia()
    let saved = await engine.save()
    if !saved {
      wantsPlay = false
      engine.pause()
    }
    isWriting = false
    refreshMedia()
    let saveAgain = saveAfterWrite && saved && !isClosed
    saveAfterWrite = false
    let advance = advanceAfterWrite && saved && !isClosed
    advanceAfterWrite = false
    if saveAgain { return await persistPosition() }
    if advance { Task { @MainActor [weak self] in await self?.trackEnded() } }
    return saved
  }

  private func adjacentTrack(_ offset: Int, autoplay: Bool) async {
    guard let manifest = engine.manifest, let current = engine.currentAsset else { return }
    let index = current.sequence + offset
    guard manifest.assets.indices.contains(index) else { return }
    await activate(manifest.assets[index], positionMs: 0, autoplay: autoplay)
  }

  private func activate(
    _ asset: AudiobookManifestAsset, positionMs: Int, autoplay: Bool
  ) async {
    guard canInteract else { return }
    isChangingTrack = true
    wantsPlay = false
    engine.pause()
    guard await persistPosition() else {
      isChangingTrack = false
      refreshMedia()
      return
    }
    let opened = await engine.activate(asset, positionMs: positionMs)
    guard !isClosed else { return }
    wantsPlay = opened && autoplay
    isChangingTrack = false
    engineUpdated()
  }

  private func trackEnded() async {
    guard !isClosed, !isChangingTrack, !isClosing else { return }
    if isWriting {
      advanceAfterWrite = true
      return
    }
    if hasNextTrack { await adjacentTrack(1, autoplay: true) } else { await saveProgress() }
  }

  private func engineUpdated() {
    guard !isClosed else { return }
    if engine.error != nil { wantsPlay = false }
    if wantsPlay, canInteract {
      wantsPlay = false
      engine.play()
    }
    let second = Int(engine.positionSeconds)
    if second != lastMediaSecond || engine.isPlaying != lastMediaPlaying
      || engine.currentAsset?.assetId != lastMediaAsset || canInteract != lastMediaCanControl
      || engine.isPlaying != lastMediaCanPause
    {
      refreshMedia()
    }
  }

  private func refreshMedia() {
    guard !isClosed, let manifest = engine.manifest, let current = engine.currentAsset else {
      return
    }
    lastMediaSecond = Int(engine.positionSeconds)
    lastMediaPlaying = engine.isPlaying
    lastMediaAsset = current.assetId
    lastMediaCanControl = canInteract
    lastMediaCanPause = engine.isPlaying
    media?.update(
      title: manifest.book.title, authors: manifest.book.authors,
      track: current.sequence, trackCount: manifest.assets.count,
      position: engine.positionSeconds, duration: engine.durationSeconds,
      rate: engine.isPlaying ? engine.playbackSpeed : 0, canControl: canInteract,
      canPause: engine.isPlaying,
      skipBack: preferences.value.skipBackSeconds, skipForward: preferences.value.skipForwardSeconds
    )
  }

  private func pauseAndSave() async {
    wantsPlay = false
    engine.pause()
    if isWriting {
      saveAfterWrite = true
    } else {
      await saveProgress()
    }
    refreshMedia()
  }

  private func handle(_ command: AudioMediaController.Command) async {
    guard !isClosed else { return }
    switch command {
    case .play:
      if canInteract, !engine.isPlaying { await togglePlayback() }
    case .pause: await pauseAndSave()
    case .toggle: await togglePlayback()
    case .seek(let seconds): await seek(to: seconds)
    case .skip(let seconds): await skip(seconds)
    case .interruptionBegan:
      resumeAfterInterruption = engine.isPlaying || wantsPlay
      await pauseAndSave()
    case .interruptionEnded(let shouldResume):
      let resume = resumeAfterInterruption && shouldResume
      resumeAfterInterruption = false
      if resume, canInteract { engine.play() }
    case .routeRemoved:
      wantsPlay = false
      resumeAfterInterruption = false
      await pauseAndSave()
    }
    refreshMedia()
  }
}
