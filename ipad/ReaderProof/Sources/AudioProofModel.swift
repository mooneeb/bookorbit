import AVFoundation
import Foundation
import Observation

@MainActor @Observable
final class AudioProofModel {
  let api: BookOrbitAPI
  let bookID: Int
  let fileID: Int
  private(set) var manifest: AudiobookManifest?
  private(set) var currentAsset: AudiobookManifestAsset?
  private(set) var state: AudiobookPlaybackState?
  private(set) var positionSeconds = 0.0
  private(set) var durationSeconds = 0.0
  private(set) var isLoading = false
  private(set) var isReady = false
  private(set) var isPlaying = false
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
  private var progressBlocked = false

  init(api: BookOrbitAPI, bookID: Int, fileID: Int) {
    self.api = api
    self.bookID = bookID
    self.fileID = fileID
  }

  var timeLabel: String {
    "\(Self.clock(positionSeconds)) / \(Self.clock(durationSeconds))"
  }

  var deliveryLabel: String {
    guard let loader else { return "No audio ranges loaded" }
    return
      "\(loader.requestCount) ranges, \(loader.deliveredBytes) bytes; peak \(loader.peakActive) transfers, \(loader.peakRequests) requests"
  }

  var canSave: Bool { isReady && !isSaving && !progressBlocked }
  var canSelectTrack: Bool { !isSaving && pendingSave == nil }

  func open() async {
    guard manifest == nil, !isLoading else { return }
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
      try validate(loaded)
      if let saved {
        guard saved.manifestRevision == loaded.revision, saved.revision >= 0,
          saved.positionMs >= 0, saved.percentage.isFinite,
          (0...100).contains(saved.percentage),
          loaded.assets.contains(where: { $0.assetId == saved.assetId })
        else { throw ConnectionError.fileChanged }
      }
      self.manifest = loaded
      self.state = saved
      let asset =
        loaded.assets.first { $0.assetId == saved?.assetId }
        ?? loaded.assets.first { $0.fileId == fileID }
      guard let asset else { throw AudioProofError.invalidManifest }
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
    guard isReady, let player else { return }
    if isPlaying {
      player.pause()
      isPlaying = false
    } else {
      do {
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try AVAudioSession.sharedInstance().setActive(true)
        player.play()
        isPlaying = true
      } catch {
        self.error = error.localizedDescription
      }
    }
  }

  func seek() async {
    guard let seconds = Double(seekSeconds), seconds.isFinite, seconds >= 0,
      seconds <= durationSeconds, isReady, let player
    else {
      error = "Enter a seek time between zero and the track duration in seconds."
      return
    }
    let generation = selectionGeneration
    let completed = await player.seek(
      to: CMTime(seconds: seconds, preferredTimescale: 1000),
      toleranceBefore: .zero, toleranceAfter: .zero)
    guard generation == selectionGeneration else { return }
    if completed {
      sample(player.currentTime())
      error = nil
    } else {
      error = "The playback engine could not complete the seek. Try again."
    }
  }

  func save() async {
    guard canSave, let manifest, let currentAsset, let sessionGeneration else { return }
    isSaving = true
    progressMessage = nil
    defer { isSaving = false }
    let pending =
      pendingSave
      ?? PutAudiobookPlaybackState(
        assetId: currentAsset.assetId, positionMs: Int((positionSeconds * 1000).rounded()),
        capturedAt: ISO8601DateFormatter().string(from: Date()),
        operationId: UUID().uuidString, baseRevision: state?.revision ?? 0,
        manifestRevision: manifest.revision)
    pendingSave = pending
    do {
      let saved: AudiobookPlaybackState = try await api.boundedJSON(
        "audiobooks/\(bookID)/playback-state", method: "PUT",
        body: JSONEncoder().encode(pending), session: sessionGeneration)
      guard saved.assetId == pending.assetId, saved.manifestRevision == manifest.revision,
        saved.revision > pending.baseRevision, saved.positionMs >= 0,
        saved.percentage.isFinite, (0...100).contains(saved.percentage)
      else { throw ConnectionError.invalidResponse }
      state = saved
      pendingSave = nil
      progressMessage = "Progress saved at \(Self.clock(Double(saved.positionMs) / 1000))."
    } catch ConnectionError.http(409) {
      progressBlocked = true
      progressMessage =
        "Progress changed in another reader. Close and reopen to load that position."
    } catch ConnectionError.http(412) {
      progressBlocked = true
      stopPlayer()
      progressMessage = "The audiobook changed. Close and reopen it before saving again."
    } catch {
      progressMessage =
        "Progress could not be confirmed. Retry Save to send the same operation. \(error.localizedDescription)"
    }
  }

  func close() {
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
    guard try await media.load(.isPlayable) else { throw AudioProofError.unsupported }
    let duration = try await media.load(.duration).seconds
    try Task.checkCancellation()
    guard generation == selectionGeneration, duration.isFinite, duration > 0,
      duration <= Double(Int.max / 1000), Double(positionMs) / 1000 <= duration + 1
    else { throw AudioProofError.invalidManifest }
    durationSeconds = duration
    let item = AVPlayerItem(asset: media)
    let player = AVPlayer(playerItem: item)
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
          self.error = message ?? AudioProofError.unsupported.localizedDescription
        }
      }
    }
    clockObserver = player.addPeriodicTimeObserver(
      forInterval: CMTime(seconds: 0.25, preferredTimescale: 1000), queue: .main
    ) { [weak self] time in
      MainActor.assumeIsolated { self?.sample(time) }
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
    if let player, player.rate == 0, seconds >= durationSeconds - 0.05 { isPlaying = false }
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
    else { throw AudioProofError.invalidManifest }
    for (index, asset) in value.assets.enumerated() {
      guard asset.sequence == index, asset.fileId > 0,
        asset.assetId.hasPrefix("aud_"),
        UUID(uuidString: String(asset.assetId.dropFirst(4))) != nil,
        AudioStreamFormat.mimeTypes[asset.format.lowercased()] != nil,
        asset.sizeBytes.map({
          $0.isFinite && $0 > 0 && $0.rounded() == $0 && $0 <= Double(safeMaximum)
        }) ?? true,
        asset.durationMs.map({ $0 > 0 && $0 <= safeMaximum }) ?? true
      else { throw AudioProofError.invalidManifest }
    }
    let assetsByID = Dictionary(uniqueKeysWithValues: value.assets.map { ($0.assetId, $0) })
    var starts: [String: Int] = [:]
    if value.assets.allSatisfy({ ($0.durationMs ?? 0) > 0 }) {
      var offset = 0
      for asset in value.assets {
        starts[asset.assetId] = offset
        let (next, overflow) = offset.addingReportingOverflow(asset.durationMs!)
        guard !overflow, next <= safeMaximum else { throw AudioProofError.invalidManifest }
        offset = next
      }
      guard offset == value.totalDurationMs else { throw AudioProofError.invalidManifest }
    }
    for (index, chapter) in value.chapters.enumerated() {
      guard chapter.sequence == index, chapter.startMs >= 0,
        chapter.endMs >= chapter.startMs, chapter.endMs <= safeMaximum,
        chapter.assetOffsetMs >= 0, chapter.assetOffsetMs <= safeMaximum,
        let asset = assetsByID[chapter.assetId],
        index == 0 || chapter.startMs >= value.chapters[index - 1].startMs
      else { throw AudioProofError.invalidManifest }
      if let start = starts[chapter.assetId] {
        let (global, overflow) = start.addingReportingOverflow(chapter.assetOffsetMs)
        guard !overflow, global == chapter.startMs,
          chapter.assetOffsetMs <= asset.durationMs!, chapter.endMs <= value.totalDurationMs
        else { throw AudioProofError.invalidManifest }
      }
    }
  }

  private static func clock(_ seconds: Double) -> String {
    let total = Int(max(0, seconds))
    return String(format: "%d:%02d", total / 60, total % 60)
  }
}
