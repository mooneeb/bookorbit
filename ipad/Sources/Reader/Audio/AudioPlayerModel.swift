import Foundation
import Observation
import UIKit

@MainActor @Observable
final class AudioPlayerModel {
  let engine: AudioPlaybackModel
  let preferences: AudioPreferencesModel
  let sleepTimer = AudioSleepTimerModel()
  private(set) var volumeMemory = AudioVolumeMemory()
  private(set) var isChangingTrack = false
  private(set) var isPositionResetting = false
  private var positionResetGeneration = UUID()
  private(set) var isWriting = false
  private(set) var isClosing = false
  private(set) var isContinuing = false
  private(set) var isApplyingSleep = false
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
  private var sleepPaused = false

  init(api: BookOrbitAPI, bookID: Int, fileID: Int, continuation: BookContinuationTarget? = nil) {
    engine = AudioPlaybackModel(
      api: api, bookID: bookID, fileID: fileID, continuation: continuation)
    preferences = AudioPreferencesModel(api: api)
  }

  var canInteract: Bool {
    !isClosed && !isPositionResetting && !isChangingTrack && !isWriting && !isClosing
      && !isContinuing
      && !isApplyingSleep
      && !preferences.isSaving
      && engine.isReady && engine.canSelectTrack && !engine.progressBlocked
  }

  var canTogglePlayback: Bool {
    !isClosed && !isPositionResetting && (engine.isPlaying || canInteract)
  }

  var canClose: Bool {
    !isClosed && !isPositionResetting && !isChangingTrack && !isWriting && !isClosing
      && !isContinuing
      && !isApplyingSleep
      && !preferences.isSaving
      && !engine.isSaving && !engine.isSeeking && !engine.isResolvingPosition
  }

  var canSave: Bool {
    !isClosed && !isPositionResetting && !isChangingTrack && !isWriting && !isClosing
      && !isContinuing && engine.canSave
  }

  var hasPreviousTrack: Bool { (engine.currentAsset?.sequence ?? 0) > 0 }
  var hasNextTrack: Bool {
    guard let manifest = engine.manifest, let current = engine.currentAsset else { return false }
    return current.sequence + 1 < manifest.assets.count
  }

  var chaptersAvailable: Bool {
    engine.manifest?.assets.allSatisfy { ($0.durationMs ?? 0) > 0 } == true
  }

  var canSetSleepTimer: Bool { canInteract && engine.error == nil }
  var canCancelSleepTimer: Bool { !isClosed && sleepTimer.isActive }
  var canExtendSleepTimer: Bool { canCancelSleepTimer && sleepTimer.canExtend }
  var canAdjustVolume: Bool { canInteract && engine.error == nil && preferences.canSave }
  var activeSleepMinutes: Int? {
    if case .minutes(let minutes) = sleepTimer.selection { return minutes }
    return nil
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
    volumeMemory.remember(preferences.value.volume)
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
          self.cancelSleepTimer()
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
      sleepPaused = false
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

  var bookmarkPosition: AudioBookmarkPosition? {
    guard engine.isReady, let manifest = engine.manifest, let current = engine.currentAsset,
      manifest.assets.allSatisfy({ ($0.durationMs ?? 0) > 0 }),
      engine.positionSeconds.isFinite, engine.positionSeconds >= 0
    else { return nil }
    let before = manifest.assets.prefix(current.sequence).reduce(0) { $0 + ($1.durationMs ?? 0) }
    let local = Int(min(Double(current.durationMs ?? 0), engine.positionSeconds * 1000).rounded())
    let milliseconds = before + local
    let chapter = manifest.chapters.last { $0.startMs <= milliseconds }
    return .init(milliseconds: milliseconds, chapterID: chapter?.id)
  }

  func jumpToBookmark(positionMs: Int) async -> Bool {
    guard canInteract, let manifest = engine.manifest,
      manifest.assets.allSatisfy({ ($0.durationMs ?? 0) > 0 }),
      positionMs >= 0, positionMs <= manifest.totalDurationMs
    else { return false }
    var before = 0
    for asset in manifest.assets {
      let duration = asset.durationMs ?? 0
      if positionMs < before + duration || asset.sequence == manifest.assets.count - 1 {
        return await activate(asset, positionMs: positionMs - before, autoplay: engine.isPlaying)
      }
      before += duration
    }
    return false
  }

  func saveProgress() async {
    guard canSave else { return }
    await persistPosition()
  }

  func reloadSettings() async {
    guard !isClosed, canClose else { return }
    await preferences.load()
    guard !isClosed else { return }
    volumeMemory.remember(preferences.value.volume)
    engine.configure(speed: preferences.value.playbackSpeed, volume: preferences.value.volume)
    refreshMedia()
  }

  func saveSettings(_ value: AudioReaderSettings, restoringVolume: Double? = nil) async -> Bool {
    guard canClose else { return false }
    let previousVolume = preferences.value.volume
    let saved = await preferences.save(value)
    if saved, !isClosed {
      volumeMemory.remember(previousVolume)
      if let restoringVolume { volumeMemory.remember(restoringVolume) }
      volumeMemory.remember(value.volume)
      engine.configure(speed: value.playbackSpeed, volume: value.volume)
      refreshMedia()
    }
    return saved
  }

  func toggleMute() async {
    guard canAdjustVolume else { return }
    var value = preferences.value
    value.volume = volumeMemory.toggledVolume(value.volume)
    _ = await saveSettings(value)
  }

  func setSleepTimer(minutes: Int) {
    if minutes == 0 {
      cancelSleepTimer()
      return
    }
    guard canSetSleepTimer, [1, 15, 30, 45, 60].contains(minutes) else { return }
    cancelSleepTimer()
    sleepTimer.start(minutes: minutes)
    startSleepCountdown()
  }

  func setEndOfChapterSleep() {
    guard canSetSleepTimer else { return }
    cancelSleepTimer()
    sleepTimer.startChapterEnd(
      manifest: engine.manifest, assetID: engine.currentAsset?.assetId,
      positionSeconds: engine.positionSeconds)
    if sleepTimer.canExtend { startSleepCountdown() }
  }

  func extendSleepTimer() {
    guard canExtendSleepTimer else { return }
    if !sleepTimer.extend() { expireSleepTimer() }
  }

  func cancelSleepTimer() {
    sleepTask?.cancel()
    sleepTask = nil
    sleepTimer.cancel()
  }

  private func startSleepCountdown() {
    sleepTask = Task { [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(1)) } catch { return }
        guard let self, !self.isClosed, !Task.isCancelled else { return }
        if self.sleepTimer.refreshCountdown() {
          self.expireSleepTimer()
          return
        }
      }
    }
  }

  private func expireSleepTimer() {
    guard !isClosed, !isPositionResetting, sleepTimer.isActive else { return }
    cancelSleepTimer()
    sleepPaused = true
    wantsPlay = false
    resumeAfterInterruption = false
    advanceAfterWrite = false
    isApplyingSleep = true
    engine.pause()
    Task { @MainActor [weak self] in
      guard let self, !self.isClosed else { return }
      await self.pauseAndSave()
      self.isApplyingSleep = false
      self.refreshMedia()
    }
  }

  func choosePosition(local: Bool) async {
    guard canClose, engine.positionConflict.isBlocked else { return }
    wantsPlay = false
    resumeAfterInterruption = false
    _ = await engine.choosePosition(local: local)
    refreshMedia()
  }

  func foreground() async {
    guard !isClosed, !isPositionResetting else { return }
    if !(await engine.checkSession()) {
      wantsPlay = false
      cancelSleepTimer()
    } else {
      await engine.refreshPosition()
      if engine.positionConflict.isBlocked { wantsPlay = false }
      if sleepTimer.refreshCountdown() { expireSleepTimer() }
    }
    refreshMedia()
  }

  func background() {
    guard !isClosed, !isPositionResetting, backgroundWrite == nil, canSave else { return }
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

  func beginContinuation() async -> Bool {
    guard canClose, engine.isReady else { return false }
    isContinuing = true
    wantsPlay = false
    resumeAfterInterruption = false
    engine.pause()
    refreshMedia()
    let saved: Bool
    if await engine.checkSession() { saved = await persistPosition() } else { saved = false }
    if !saved { isContinuing = false }
    refreshMedia()
    return saved && !isClosed
  }

  func endContinuation() {
    isContinuing = false
    refreshMedia()
  }

  func reconfirmContinuation() async -> Bool {
    isContinuing = false
    return await beginContinuation()
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

  var canResetPosition: Bool {
    !isClosed && !isPositionResetting && !isClosing && !isContinuing && !preferences.isSaving
      && engine.manifest != nil
  }

  func beginPositionReset() async throws {
    guard !isClosed else { throw CancellationError() }
    let request = UUID()
    positionResetGeneration = request
    isPositionResetting = true
    wantsPlay = false
    resumeAfterInterruption = false
    saveAfterWrite = false
    advanceAfterWrite = false
    cancelSleepTimer()
    engine.pause()
    refreshMedia()
    try await NativePositionResetWait.drain {
      self.isWriting || self.isChangingTrack || self.isApplyingSleep || self.engine.isSaving
        || self.engine.isSeeking || self.engine.isResolvingPosition || self.engine.isLoading
    }
    await backgroundWrite?.value
    try Task.checkCancellation()
    guard request == positionResetGeneration, isPositionResetting else { throw CancellationError() }
    engine.beginPositionReset()
    refreshMedia()
  }

  func cancelPositionReset() {
    positionResetGeneration = UUID()
    isPositionResetting = false
    engine.cancelPositionReset()
    refreshMedia()
  }

  func close() {
    guard !isClosed else { return }
    isClosed = true
    wantsPlay = false
    autosave?.cancel()
    autosave = nil
    cancelSleepTimer()
    backgroundWrite?.cancel()
    backgroundWrite = nil
    media?.close()
    media = nil
    preferences.close()
    engine.close()
  }

  @discardableResult
  private func persistPosition() async -> Bool {
    guard engine.canSave, !isClosed, !isPositionResetting, !isWriting else { return false }
    isWriting = true
    refreshMedia()
    let saved = await engine.save()
    if !saved {
      wantsPlay = false
      engine.pause()
    }
    isWriting = false
    refreshMedia()
    let saveAgain = saveAfterWrite && saved && !isClosed && !isPositionResetting
    saveAfterWrite = false
    let advance = advanceAfterWrite && saved && !isClosed && !isPositionResetting && !sleepPaused
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

  @discardableResult
  private func activate(
    _ asset: AudiobookManifestAsset, positionMs: Int, autoplay: Bool
  ) async -> Bool {
    guard canInteract else { return false }
    isChangingTrack = true
    wantsPlay = false
    engine.pause()
    guard await persistPosition() else {
      isChangingTrack = false
      refreshMedia()
      return false
    }
    guard !sleepPaused || !autoplay else {
      isChangingTrack = false
      refreshMedia()
      return false
    }
    let opened = await engine.activate(asset, positionMs: positionMs)
    guard !isClosed else { return false }
    wantsPlay = opened && autoplay && !sleepPaused && !isPositionResetting
    isChangingTrack = false
    engineUpdated()
    return opened
  }

  private func trackEnded() async {
    guard !isClosed, !isPositionResetting, !isChangingTrack, !isClosing, !sleepPaused else {
      return
    }
    if sleepTimer.refreshCountdown()
      || sleepTimer.reachedChapterEnd(
        assetID: engine.currentAsset?.assetId,
        positionSeconds: max(engine.positionSeconds, engine.durationSeconds),
        isPlaying: true)
    {
      expireSleepTimer()
      return
    }
    if isWriting {
      advanceAfterWrite = true
      return
    }
    if hasNextTrack { await adjacentTrack(1, autoplay: true) } else { await saveProgress() }
  }

  private func engineUpdated() {
    guard !isClosed, !isPositionResetting else { return }
    if engine.error != nil {
      wantsPlay = false
      cancelSleepTimer()
    }
    if sleepTimer.refreshCountdown()
      || sleepTimer.reachedChapterEnd(
        assetID: engine.currentAsset?.assetId, positionSeconds: engine.positionSeconds,
        isPlaying: engine.isPlaying)
    {
      expireSleepTimer()
      return
    }
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
    guard !isClosed, !isPositionResetting else { return }
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
