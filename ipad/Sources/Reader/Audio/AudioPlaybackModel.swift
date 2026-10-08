import AVFoundation
import Foundation
import Observation

@MainActor @Observable
final class AudioPlaybackModel {
  let api: BookOrbitAPI
  let bookID: Int
  let fileID: Int
  let positionConflict = ReaderPositionConflictState()
  private let continuation: BookContinuationTarget?
  private(set) var manifest: AudiobookManifest?
  private(set) var currentAsset: AudiobookManifestAsset?
  private(set) var state: AudiobookPlaybackState?
  private(set) var positionSeconds = 0.0
  private(set) var durationSeconds = 0.0
  private(set) var isLoading = false
  private(set) var isReady = false
  private(set) var isPlaying = false
  private(set) var isPositionResetting = false
  private(set) var isSaving = false
  private(set) var error: String?
  private(set) var progressMessage: String?
  var seekSeconds = ""
  @ObservationIgnored private var player: AVPlayer?
  @ObservationIgnored private var loader: AudioResourceLoader?
  @ObservationIgnored private var preparation: Task<Void, Never>?
  @ObservationIgnored private var statusObservation: NSKeyValueObservation?
  @ObservationIgnored private var clockObserver: Any?
  private var selectionGeneration = UUID()
  private var sessionGeneration: UUID?
  private var pendingSave: PutAudiobookPlaybackState?
  private(set) var progressBlocked = false
  private var isClosed = false
  private var conflictLocal: PutAudiobookPlaybackState?
  private var conflictRemote: AudiobookPlaybackState?
  private var resolutionChoice: Bool?
  private var pendingSaveBody: Data?
  private(set) var isResolvingPosition = false
  private(set) var isSeeking = false
  private(set) var playbackSpeed = 1.0
  private(set) var volume = 1.0
  @ObservationIgnored var updated: (() -> Void)?
  @ObservationIgnored var ended: (() -> Void)?
  private var endReported = false

  init(api: BookOrbitAPI, bookID: Int, fileID: Int, continuation: BookContinuationTarget? = nil) {
    self.api = api
    self.bookID = bookID
    self.fileID = fileID
    self.continuation = continuation
  }

  var timeLabel: String {
    "\(Self.clock(positionSeconds)) / \(Self.clock(durationSeconds, rounding: .toNearestOrAwayFromZero))"
  }

  var deliveryLabel: String {
    guard let loader else { return "No audio ranges loaded" }
    return
      "\(loader.requestCount) ranges, \(loader.deliveredBytes) bytes; peak \(loader.peakActive) transfers, \(loader.peakRequests) requests"
  }

  var hasPendingSave: Bool { pendingSave != nil }
  var canSave: Bool {
    isReady && !isSaving && !isSeeking && !progressBlocked && !isResolvingPosition
      && !isPositionResetting && !isClosed
  }
  var canSelectTrack: Bool {
    !isSaving && !isSeeking && !isResolvingPosition && pendingSave == nil
      && !positionConflict.isBlocked && !isPositionResetting && !isClosed
  }

  func open() async {
    guard manifest == nil, !isLoading, !isClosed else { return }
    isLoading = true
    error = nil
    defer { isLoading = false }
    do {
      let session = try await api.authenticatedSessionGeneration()
      sessionGeneration = session
      async let manifest: AudiobookManifest = api.boundedJSON(
        "audiobooks/\(bookID)/manifest", session: session)
      async let state: AudiobookPlaybackState? = api.boundedJSON(
        "audiobooks/\(bookID)/playback-state", session: session)
      let (loaded, saved) = try await (manifest, state)
      try Task.checkCancellation()
      guard !isClosed else { return }
      try validate(loaded)
      if let saved {
        guard saved.manifestRevision == loaded.revision, saved.revision >= 0,
          saved.positionMs >= 0, saved.percentage.isFinite,
          (0...100).contains(saved.percentage),
          loaded.assets.contains(where: { $0.assetId == saved.assetId })
        else { throw ConnectionError.fileChanged }
      }
      if let continuation {
        guard continuation.fileId == fileID, saved?.assetId == continuation.assetId,
          saved?.positionMs == continuation.positionMs
        else {
          throw NativeContinuationError(
            message:
              "The destination listening position changed. Close this player and save the source again before continuing."
          )
        }
      }
      self.manifest = loaded
      self.state = saved
      let asset =
        loaded.assets.first { $0.assetId == saved?.assetId }
        ?? loaded.assets.first { $0.fileId == fileID }
      guard let asset else { throw AudioPlaybackError.invalidManifest }
      let resumePosition = saved.flatMap { $0.assetId == asset.assetId ? $0.positionMs : nil } ?? 0
      begin(asset, positionMs: resumePosition)
      await preparation?.value
    } catch {
      if !Task.isCancelled { self.error = error.localizedDescription }
    }
  }

  func select(_ asset: AudiobookManifestAsset) {
    guard canSelectTrack, manifest?.assets.contains(asset) == true else { return }
    begin(asset, positionMs: 0)
  }

  func selectChapter(_ chapter: AudiobookManifestChapter) {
    guard canSelectTrack, let manifest, manifest.chapters.contains(chapter),
      manifest.assets.allSatisfy({ ($0.durationMs ?? 0) > 0 }),
      let asset = manifest.assets.first(where: { $0.assetId == chapter.assetId })
    else { return }
    begin(asset, positionMs: chapter.assetOffsetMs)
  }

  func retryPlayback() {
    guard canSelectTrack, let currentAsset else { return }
    let savedPosition =
      state.flatMap { $0.assetId == currentAsset.assetId ? $0.positionMs : nil } ?? 0
    let position = positionSeconds > 0 ? Int((positionSeconds * 1000).rounded()) : savedPosition
    begin(currentAsset, positionMs: position)
  }

  func togglePlayback() {
    if isPlaying { pause() } else { play() }
  }

  func play() {
    guard isReady, !isClosed, !isPositionResetting, let player else { return }
    do {
      try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
      try AVAudioSession.sharedInstance().setActive(true)
      player.playImmediately(atRate: Float(playbackSpeed))
      isPlaying = true
      updated?()
    } catch {
      self.error = error.localizedDescription
    }
  }

  func pause() {
    player?.pause()
    isPlaying = false
    if let player { sample(player.currentTime()) }
    updated?()
  }

  func configure(speed: Double, volume: Double) {
    guard speed.isFinite, (0.5...3).contains(speed), volume.isFinite,
      (0...1).contains(volume), !isClosed
    else { return }
    playbackSpeed = speed
    self.volume = volume
    player?.volume = Float(volume)
    if isPlaying { player?.rate = Float(speed) }
    updated?()
  }

  func seek() async {
    guard let seconds = Double(seekSeconds) else {
      error = "Enter a seek time between zero and the track duration in seconds."
      return
    }
    await seek(to: seconds)
  }

  @discardableResult
  func seek(to seconds: Double) async -> Bool {
    guard seconds.isFinite, seconds >= 0, seconds <= durationSeconds,
      isReady, canSelectTrack, let player
    else {
      error = "Enter a seek time between zero and the track duration in seconds."
      return false
    }
    isSeeking = true
    defer { isSeeking = false }
    let generation = selectionGeneration
    let completed = await player.seek(
      to: CMTime(seconds: seconds, preferredTimescale: 1000),
      toleranceBefore: .zero, toleranceAfter: .zero)
    guard generation == selectionGeneration, !isClosed else { return false }
    if completed {
      endReported = false
      sample(player.currentTime())
      error = nil
      return true
    }
    error = "The playback engine could not complete the seek. Try again."
    return false
  }

  @discardableResult
  func activate(_ asset: AudiobookManifestAsset, positionMs: Int) async -> Bool {
    guard canSelectTrack, positionMs >= 0, manifest?.assets.contains(asset) == true else {
      return false
    }
    begin(asset, positionMs: positionMs)
    await preparation?.value
    return !isClosed && error == nil && currentAsset?.assetId == asset.assetId
  }

  func checkSession() async -> Bool {
    guard !isClosed, let sessionGeneration else { return false }
    do {
      guard try await api.authenticatedSessionGeneration() == sessionGeneration else {
        throw ConnectionError.expiredSession
      }
      return true
    } catch {
      pause()
      self.error = error.localizedDescription
      return false
    }
  }

  @discardableResult
  func save(resolvingConflict: Bool = false) async -> Bool {
    guard canSave || (resolvingConflict && isReady && !isSaving && !isSeeking && !isClosed),
      let manifest, let currentAsset, let sessionGeneration
    else { return false }
    isSaving = true
    progressMessage = nil
    defer { isSaving = false }
    let generation = selectionGeneration
    if let player { sample(player.currentTime()) }
    let pending =
      pendingSave
      ?? PutAudiobookPlaybackState(
        assetId: currentAsset.assetId, positionMs: Int((positionSeconds * 1000).rounded()),
        capturedAt: ISO8601DateFormatter().string(from: Date()),
        operationId: UUID().uuidString, baseRevision: state?.revision ?? 0,
        manifestRevision: manifest.revision)
    pendingSave = pending
    do {
      let body = try pendingSaveBody ?? JSONEncoder().encode(pending)
      pendingSaveBody = body
      let saved: AudiobookPlaybackState = try await api.boundedJSON(
        "audiobooks/\(bookID)/playback-state", method: "PUT",
        body: body, session: sessionGeneration)
      guard !isClosed, generation == selectionGeneration else { return false }
      let expectedPosition = min(pending.positionMs, currentAsset.durationMs ?? pending.positionMs)
      guard let savedAt = Self.timestamp(saved.capturedAt),
        let pendingAt = Self.timestamp(pending.capturedAt), savedAt == pendingAt,
        saved.assetId == pending.assetId, saved.manifestRevision == manifest.revision,
        saved.revision == pending.baseRevision + 1, saved.positionMs == expectedPosition,
        saved.percentage.isFinite, (0...100).contains(saved.percentage)
      else { throw ConnectionError.invalidResponse }
      state = saved
      pendingSave = nil
      pendingSaveBody = nil
      progressBlocked = false
      positionConflict.clear()
      conflictLocal = nil
      conflictRemote = nil
      resolutionChoice = nil
      progressMessage = "Progress saved at \(Self.clock(Double(saved.positionMs) / 1000))."
      return true
    } catch ConnectionError.http(409) {
      guard !isClosed else { return false }
      progressBlocked = true
      resolutionChoice = nil
      pause()
      do {
        presentConflict(local: conflictLocal ?? pending, remote: try await remotePosition())
      } catch {
        progressMessage =
          "Progress changed in another reader. Retry loading its position. \(error.localizedDescription)"
      }
    } catch ConnectionError.http(412) {
      guard !isClosed else { return false }
      progressBlocked = true
      stopPlayer()
      progressMessage = "The audiobook changed. Close and reopen it before saving again."
    } catch {
      guard !isClosed else { return false }
      progressMessage =
        "Progress could not be confirmed. Retry Save to send the same operation. \(error.localizedDescription)"
    }
    return false
  }

  func retryPositionChoices() async {
    guard !isClosed, !isSaving, !isResolvingPosition, progressBlocked, let pendingSave else {
      return
    }
    do {
      presentConflict(local: conflictLocal ?? pendingSave, remote: try await remotePosition())
    } catch { if !isClosed { progressMessage = error.localizedDescription } }
  }

  func refreshPosition() async {
    guard !isClosed, !isSaving, !isSeeking, !isResolvingPosition, !positionConflict.isBlocked,
      let manifest, let currentAsset
    else { return }
    do {
      let remote = try await remotePosition()
      if remote?.revision != state?.revision {
        let local =
          pendingSave
          ?? PutAudiobookPlaybackState(
            assetId: currentAsset.assetId, positionMs: Int((positionSeconds * 1000).rounded()),
            capturedAt: ISO8601DateFormatter().string(from: Date()), operationId: UUID().uuidString,
            baseRevision: state?.revision ?? 0, manifestRevision: manifest.revision)
        pendingSave = local
        pause()
        presentConflict(local: local, remote: remote)
      }
    } catch { if !isClosed { progressMessage = error.localizedDescription } }
  }

  func choosePosition(local: Bool) async -> Bool {
    guard !isClosed, !isSaving, !isSeeking, !isResolvingPosition, positionConflict.isBlocked,
      let conflictLocal, let manifest
    else { return false }
    isResolvingPosition = true
    pause()
    defer { isResolvingPosition = false }
    do {
      if resolutionChoice == local, pendingSave != nil {
        return await save(resolvingConflict: true)
      }
      let remote = try await remotePosition()
      guard remote?.revision == conflictRemote?.revision else {
        presentConflict(local: conflictLocal, remote: remote)
        progressMessage =
          "The other reader moved again. Review its new listening position before choosing."
        return false
      }
      let assetID = local ? conflictLocal.assetId : remote?.assetId ?? manifest.assets[0].assetId
      let offset = local ? conflictLocal.positionMs : remote?.positionMs ?? 0
      guard let asset = manifest.assets.first(where: { $0.assetId == assetID }) else {
        throw ConnectionError.fileChanged
      }
      let chosen = PutAudiobookPlaybackState(
        assetId: assetID, positionMs: offset,
        capturedAt: ISO8601DateFormatter().string(from: Date()), operationId: UUID().uuidString,
        baseRevision: remote?.revision ?? 0, manifestRevision: manifest.revision)
      pendingSave = chosen
      pendingSaveBody = nil
      resolutionChoice = local
      begin(asset, positionMs: offset)
      await preparation?.value
      guard !isClosed, await checkSession(), isReady else { return false }
      return await save(resolvingConflict: true)
    } catch { if !isClosed { progressMessage = error.localizedDescription } }
    return false
  }

  private func remotePosition() async throws -> AudiobookPlaybackState? {
    guard await checkSession(), let manifest else { throw ConnectionError.expiredSession }
    let remote: AudiobookPlaybackState? = try await api.boundedJSON(
      "audiobooks/\(bookID)/playback-state", byteLimit: 16 * 1024, session: sessionGeneration)
    guard await checkSession() else { throw ConnectionError.expiredSession }
    if let remote {
      guard remote.manifestRevision == manifest.revision, remote.revision >= 0,
        remote.positionMs >= 0, remote.percentage.isFinite, (0...100).contains(remote.percentage),
        let asset = manifest.assets.first(where: { $0.assetId == remote.assetId }),
        remote.positionMs <= (asset.durationMs ?? Int.max)
      else { throw ConnectionError.fileChanged }
    }
    return remote
  }

  private func presentConflict(local: PutAudiobookPlaybackState, remote: AudiobookPlaybackState?) {
    guard !isClosed else { return }
    conflictLocal = local
    conflictRemote = remote
    progressBlocked = true
    positionConflict.present(
      local: positionLabel(assetID: local.assetId, offset: local.positionMs),
      remote: remote.map { positionLabel(assetID: $0.assetId, offset: $0.positionMs) }
        ?? "Beginning of audiobook")
    progressMessage = "Progress changed in another reader. Choose a resume position before saving."
  }

  private func positionLabel(assetID: String, offset: Int) -> String {
    let track =
      manifest?.assets.first(where: { $0.assetId == assetID }).map { $0.sequence + 1 } ?? 1
    return "Track \(track), \(Self.clock(Double(offset) / 1000))"
  }

  func beginPositionReset() {
    isPositionResetting = true
    selectionGeneration = UUID()
    preparation?.cancel()
    preparation = nil
    stopPlayer()
  }

  func cancelPositionReset() {
    guard isPositionResetting else { return }
    isPositionResetting = false
    if let currentAsset {
      begin(currentAsset, positionMs: Int((positionSeconds * 1000).rounded()))
    }
  }

  func acknowledgePositionReset() {
    state = nil
    pendingSave = nil
    pendingSaveBody = nil
    conflictLocal = nil
    conflictRemote = nil
    resolutionChoice = nil
    progressBlocked = false
    positionConflict.clear()
    progressMessage = nil
  }

  func close() {
    isClosed = true
    updated = nil
    ended = nil
    selectionGeneration = UUID()
    preparation?.cancel()
    preparation = nil
    stopPlayer()
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }

  private func begin(_ asset: AudiobookManifestAsset, positionMs: Int) {
    preparation?.cancel()
    stopPlayer()
    currentAsset = asset
    positionSeconds = 0
    durationSeconds = 0
    endReported = false
    error = nil
    isLoading = true
    selectionGeneration = UUID()
    let generation = selectionGeneration
    preparation = Task { [weak self] in
      guard let self else { return }
      defer { if generation == self.selectionGeneration { self.isLoading = false } }
      do {
        try await self.prepare(asset, positionMs: positionMs, generation: generation)
      } catch {
        if generation == self.selectionGeneration, !Task.isCancelled {
          self.stopPlayer()
          self.error = error.localizedDescription
        }
      }
    }
  }

  private func prepare(
    _ asset: AudiobookManifestAsset, positionMs: Int, generation: UUID
  ) async throws {
    guard let sessionGeneration else { throw ConnectionError.expiredSession }
    let descriptor = AudioAssetDescriptor(
      bookID: bookID, assetID: asset.assetId, format: asset.format.lowercased(),
      sizeBytes: asset.sizeBytes.map(Int64.init))
    let loader = AudioResourceLoader(
      api: api, descriptor: descriptor, sessionGeneration: sessionGeneration)
    self.loader = loader
    let media = AVURLAsset(url: loader.url)
    media.resourceLoader.setDelegate(loader, queue: .main)
    guard try await media.load(.isPlayable) else { throw AudioPlaybackError.unsupported }
    let duration = try await media.load(.duration).seconds
    try Task.checkCancellation()
    guard generation == selectionGeneration, duration.isFinite, duration > 0,
      duration <= Double(Int.max / 1000), Double(positionMs) / 1000 <= duration + 1
    else { throw AudioPlaybackError.invalidManifest }
    durationSeconds = duration
    let item = AVPlayerItem(asset: media)
    let player = AVPlayer(playerItem: item)
    player.volume = Float(volume)
    self.player = player
    statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
      let ready = item.status == .readyToPlay
      let failed = item.status == .failed
      let message = item.error?.localizedDescription
      Task { @MainActor in
        guard let self, generation == self.selectionGeneration else { return }
        self.isReady = ready
        if failed {
          self.player?.pause()
          self.isPlaying = false
          self.error = message ?? AudioPlaybackError.unsupported.localizedDescription
        }
        self.updated?()
      }
    }
    clockObserver = player.addPeriodicTimeObserver(
      forInterval: CMTime(seconds: 0.25, preferredTimescale: 1000), queue: .main
    ) { [weak self] time in
      MainActor.assumeIsolated {
        guard let self, generation == self.selectionGeneration, !self.isPositionResetting else {
          return
        }
        self.sample(time)
      }
    }
    if positionMs > 0 {
      let completed = await player.seek(
        to: CMTime(seconds: min(duration, Double(positionMs) / 1000), preferredTimescale: 1000),
        toleranceBefore: .zero, toleranceAfter: .zero)
      try Task.checkCancellation()
      guard completed else { throw ConnectionError.invalidResponse }
    }
    if generation == selectionGeneration { sample(player.currentTime()) }
  }

  private func sample(_ time: CMTime) {
    let seconds = time.seconds
    guard seconds.isFinite, seconds >= 0 else { return }
    positionSeconds = min(durationSeconds, seconds)
    if let player, player.rate == 0, durationSeconds > 0, seconds >= durationSeconds - 0.05 {
      let wasPlaying = isPlaying
      isPlaying = false
      if wasPlaying, !endReported {
        endReported = true
        ended?()
      }
    }
    updated?()
  }

  private func stopPlayer() {
    player?.pause()
    if let clockObserver { player?.removeTimeObserver(clockObserver) }
    clockObserver = nil
    statusObservation?.invalidate()
    statusObservation = nil
    player?.replaceCurrentItem(with: nil)
    player = nil
    loader?.close()
    loader = nil
    isReady = false
    isPlaying = false
  }

  private func validate(_ value: AudiobookManifest) throws {
    let safeMaximum = 9_007_199_254_740_991
    guard value.schema == AudiobookVocabulary.schema,
      value.schemaVersion == AudiobookVocabulary.version,
      value.book.id == bookID, value.revision.count == 64,
      value.revision.allSatisfy(\.isHexDigit),
      (1...4096).contains(value.assets.count), value.chapters.count <= 4096,
      value.totalDurationMs >= 0, value.totalDurationMs <= safeMaximum,
      Set(value.assets.map(\.assetId)).count == value.assets.count,
      Set(value.assets.map(\.fileId)).count == value.assets.count,
      Set(value.chapters.map(\.id)).count == value.chapters.count
    else { throw AudioPlaybackError.invalidManifest }
    for (index, asset) in value.assets.enumerated() {
      guard asset.sequence == index, asset.fileId > 0,
        asset.assetId.hasPrefix("aud_"),
        UUID(uuidString: String(asset.assetId.dropFirst(4))) != nil,
        AudioStreamFormat.mimeTypes[asset.format.lowercased()] != nil,
        asset.sizeBytes.map({
          $0.isFinite && $0 > 0 && $0.rounded() == $0 && $0 <= Double(safeMaximum)
        }) ?? true,
        asset.durationMs.map({ $0 > 0 && $0 <= safeMaximum }) ?? true
      else { throw AudioPlaybackError.invalidManifest }
    }
    let assetsByID = Dictionary(uniqueKeysWithValues: value.assets.map { ($0.assetId, $0) })
    var starts: [String: Int] = [:]
    if value.assets.allSatisfy({ ($0.durationMs ?? 0) > 0 }) {
      var offset = 0
      for asset in value.assets {
        starts[asset.assetId] = offset
        let (next, overflow) = offset.addingReportingOverflow(asset.durationMs!)
        guard !overflow, next <= safeMaximum else { throw AudioPlaybackError.invalidManifest }
        offset = next
      }
      guard offset == value.totalDurationMs else { throw AudioPlaybackError.invalidManifest }
    }
    for (index, chapter) in value.chapters.enumerated() {
      guard chapter.sequence == index, chapter.startMs >= 0,
        chapter.endMs >= chapter.startMs, chapter.endMs <= safeMaximum,
        chapter.assetOffsetMs >= 0, chapter.assetOffsetMs <= safeMaximum,
        let asset = assetsByID[chapter.assetId],
        index == 0 || chapter.startMs >= value.chapters[index - 1].startMs
      else { throw AudioPlaybackError.invalidManifest }
      if let start = starts[chapter.assetId] {
        let (global, overflow) = start.addingReportingOverflow(chapter.assetOffsetMs)
        guard !overflow, global == chapter.startMs,
          chapter.assetOffsetMs <= asset.durationMs!, chapter.endMs <= value.totalDurationMs
        else { throw AudioPlaybackError.invalidManifest }
      }
    }
  }

  private static func timestamp(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
  }

  static func clock(
    _ seconds: Double, rounding: FloatingPointRoundingRule = .down
  ) -> String {
    guard seconds.isFinite, seconds >= 0, seconds <= Double(Int.max / 1000) else {
      return "0:00"
    }
    let total = Int(seconds.rounded(rounding))
    return "\(total / 60):\(String(format: "%02d", total % 60))"
  }
}
