import Foundation
import Observation

@MainActor @Observable
final class NativeRecordedModel {
  enum State: String { case idle, loading, playing, paused, error }
  let reader: EPUBReaderModel
  let title: String
  let position: NativeRecordedPositionModel
  private(set) var state = State.idle
  private(set) var clip: EpubMediaOverlayClip?
  private(set) var segment: EPUBRecordedSegment?
  private(set) var elapsed = 0.0
  private(set) var duration = 0.0
  private(set) var error: String?
  private(set) var isPositionResetting = false
  private var positionResetGeneration = UUID()
  private(set) var isBusy = false
  private(set) var follow = true
  private(set) var rate = 1.0
  var seekSeconds = ""
  @ObservationIgnored var beforePlayback: (@MainActor () async -> Bool)?
  @ObservationIgnored private let audio = NativeRecordedAudioController()
  @ObservationIgnored private var media: AudioMediaController?
  @ObservationIgnored private var sessionTask: Task<Void, Never>?
  private var session: UUID?
  private var nextSection: Int?
  private var previousSection: Int?
  private var nextCursor: Int?
  private var pendingEnd = false
  private var isClosed = false
  private var operation = UUID()
  private var lastJournalWrite = Date.distantPast
  private var lastServerWrite = Date.distantPast

  init(reader: EPUBReaderModel, title: String) {
    self.reader = reader
    self.title = title
    position = NativeRecordedPositionModel(api: reader.api, fileID: reader.file.id)
  }

  var isAvailable: Bool {
    reader.info?.manifest.contains(where: { $0.mediaOverlay != nil }) == true
  }
  var isActive: Bool { state == .playing || state == .paused || state == .loading }
  var isPlaying: Bool { state == .playing }
  var canControl: Bool {
    !isPositionResetting && !isBusy && !position.isSaving && !isClosed && position.hasLoaded
      && !position.conflict.isBlocked
  }
  var timeLabel: String {
    "\(elapsed.formatted(.number.precision(.fractionLength(1)))) / \(duration.formatted(.number.precision(.fractionLength(1)))) seconds in segment"
  }

  func open() async {
    guard !position.hasLoaded, !isBusy, !isClosed else { return }
    isBusy = true
    defer { isBusy = false }
    do {
      session = try await reader.api.authenticatedSessionGeneration()
      try await position.load()
      await reader.describePositionConflict(position.canonical)
    } catch { self.error = error.localizedDescription }
  }

  func startCurrent() async {
    guard canControl, isAvailable, let cfi = reader.selectionCFI ?? reader.visibleLocation?.cfi,
      let section = reader.visibleLocation?.chapterIndex
    else {
      error = NativeRecordedError.unavailable.localizedDescription
      return
    }
    guard await stopAndSave(), await beforePlayback?() ?? true else { return }
    await perform {
      var cursor = 0
      while true {
        let page = try await self.page(section: section, cursor: cursor)
        if let match = try await self.reader.recordedMatch(page.items, cfi: cfi),
          let clip = page.items.first(where: { $0.index == match })
        {
          try await self.activate(clip, page: page, offset: 0, play: true)
          return
        }
        guard let next = page.nextCursor else { throw NativeRecordedError.unavailable }
        cursor = next
      }
    }
  }

  func resumeSaved() async {
    guard canControl, let saved = position.saved else { return }
    guard await stopAndSave(), await beforePlayback?() ?? true else { return }
    await perform {
      var cursor = 0
      while true {
        let page = try await self.page(section: saved.sectionIndex, cursor: cursor)
        if let clip = page.items.first(where: { Self.fragment($0) == saved.fragment }) {
          let offset =
            saved.positionSeconds.flatMap { seconds in
              clip.startSeconds.map { max(0, seconds - $0) }
            } ?? saved.offsetSeconds
          try await self.activate(clip, page: page, offset: offset, play: true)
          return
        }
        guard let next = page.nextCursor else { throw NativeRecordedError.unavailable }
        cursor = next
      }
    }
  }

  func togglePlayback() async {
    guard canControl else { return }
    if isPlaying {
      await pause()
      return
    }
    if clip == nil {
      await resumeSaved()
      return
    }
    guard await beforePlayback?() ?? true else { return }
    do {
      try await position.checkSession()
      try audio.play()
      state = .playing
      installMedia()
      updateMedia()
    } catch { await fail(error) }
  }

  func pause() async {
    audio.pause()
    if clip != nil { state = .paused }
    do { try capture() } catch { self.error = error.localizedDescription }
    _ = await position.flush()
    updateMedia()
  }

  @discardableResult
  func stopAndSave() async -> Bool {
    guard !isClosed, !isBusy, !position.isSaving else { return false }
    isBusy = true
    defer { isBusy = false }
    audio.pause()
    if clip != nil { state = .paused }
    do { try capture() } catch {
      self.error = error.localizedDescription
      return false
    }
    let saved = position.hasLoaded ? await position.flush() : true
    operation = UUID()
    pendingEnd = false
    audio.close()
    sessionTask?.cancel()
    sessionTask = nil
    media?.close()
    media = nil
    await reader.clearRecordedHighlight()
    audio.releaseAudioSession()
    clip = nil
    segment = nil
    state = saved ? .idle : .error
    return saved
  }

  func moveClip(forward: Bool) async {
    guard canControl, let current = clip else { return }
    let wasPlaying = isPlaying
    let section =
      forward && nextCursor == nil
      ? nextSection
      : (!forward && current.sectionClipIndex == 0 ? previousSection : current.sectionIndex)
    let cursor = forward ? current.sectionClipIndex + 1 : current.sectionClipIndex - 1
    guard forward || cursor >= 0 || previousSection != nil, let section else {
      await pause()
      return
    }
    guard await stopAndSave() else { return }
    await perform {
      var page = try await self.page(
        section: section, cursor: section == current.sectionIndex ? cursor : 0)
      if !forward && section != current.sectionIndex && page.totalClips > 0 {
        page = try await self.page(section: section, cursor: page.totalClips - 1)
      }
      guard let next = page.items.first else { throw NativeRecordedError.unavailable }
      try await self.activate(next, page: page, offset: 0, play: wasPlaying)
    }
  }

  func seek() async {
    guard canControl, let seconds = Double(seekSeconds) else {
      error = NativeRecordedError.invalidSeek.localizedDescription
      return
    }
    await perform {
      let playing = self.isPlaying
      self.audio.pause()
      try await self.audio.seek(seconds)
      self.elapsed = self.audio.elapsed
      try self.capture()
      _ = await self.position.flush()
      if playing { try self.audio.play() }
    }
  }

  func setFollow(_ value: Bool) async {
    guard canControl else { return }
    follow = value
    if let clip {
      await perform {
        let playing = self.isPlaying
        self.audio.pause()
        self.segment = try await self.reader.highlightRecorded(clip, follow: value)
        if playing { try self.audio.play() }
      }
    }
  }

  func setRate(_ value: Double) {
    guard canControl, value.isFinite, (0.5...4).contains(value) else { return }
    rate = value
    audio.setRate(value)
    updateMedia()
  }

  func foreground() async {
    guard !isPositionResetting else { return }
    do {
      try await position.checkSession()
      await position.refresh()
      await reader.describePositionConflict(position.canonical)
      if position.conflict.isBlocked { await freezeForPositionChoice() }
    } catch { await fail(error) }
  }

  func freezeForPositionChoice() async {
    guard !isClosed else { return }
    operation = UUID()
    pendingEnd = false
    audio.close()
    sessionTask?.cancel()
    sessionTask = nil
    media?.close()
    media = nil
    clip = nil
    segment = nil
    state = .idle
    await reader.clearRecordedHighlight()
    audio.releaseAudioSession()
  }

  func choosePosition(local: Bool) async {
    guard !isClosed, !isBusy, position.conflict.isBlocked else { return }
    await freezeForPositionChoice()
    guard await position.choosePosition(local: local), !isClosed else {
      await reader.describePositionConflict(position.canonical)
      return
    }
    await resumeSaved()
  }

  func beginPositionReset() async throws {
    guard !isClosed else { throw CancellationError() }
    let request = UUID()
    positionResetGeneration = request
    isPositionResetting = true
    audio.pause()
    try await NativePositionResetWait.drain {
      self.isBusy || self.position.isSaving || self.position.canonical.isResolving
    }
    guard request == positionResetGeneration, isPositionResetting else { throw CancellationError() }
    _ = await stopAndSave()
    try Task.checkCancellation()
    guard request == positionResetGeneration, isPositionResetting else { throw CancellationError() }
    position.canonical.suspendForReset(true)
    try Task.checkCancellation()
  }

  func cancelPositionReset() {
    positionResetGeneration = UUID()
    isPositionResetting = false
    position.canonical.suspendForReset(false)
  }

  func acknowledgePositionReset() { position.acknowledgeReset() }

  func close() {
    do { if !isPositionResetting { try capture() } } catch {
      self.error = error.localizedDescription
    }
    isClosed = true
    operation = UUID()
    sessionTask?.cancel()
    sessionTask = nil
    audio.close()
    media?.close()
    media = nil
    audio.releaseAudioSession()
    position.close()
  }

  private func perform(_ action: @MainActor () async throws -> Void) async {
    guard !isBusy, !isClosed, !isPositionResetting else { return }
    isBusy = true
    error = nil
    defer { isBusy = false }
    do {
      try await position.checkSession()
      try await action()
    } catch { await fail(error) }
  }

  private func page(section: Int, cursor: Int) async throws -> EpubMediaOverlayClipsPage {
    let page: EpubMediaOverlayClipsPage = try await reader.api.boundedJSON(
      "epub/\(reader.bookID)/media-overlay/clips",
      query: [
        URLQueryItem(name: "fileId", value: String(reader.file.id)),
        URLQueryItem(name: "sectionIndex", value: String(section)),
        URLQueryItem(name: "cursor", value: String(cursor)),
        URLQueryItem(name: "limit", value: "64"),
      ], byteLimit: 512 * 1024, session: session)
    try await position.checkSession()
    guard page.bookId == reader.bookID, page.fileId == reader.file.id, page.sectionIndex == section,
      page.items.count <= 64, page.nextCursor.map({ $0 > cursor }) ?? true,
      page.nextSectionIndex.map({ $0 > section && $0 < reader.chapterCount }) ?? true,
      page.items.allSatisfy({ Self.valid($0) && $0.sectionIndex == section }),
      Set(page.items.map(\.index)).count == page.items.count
    else { throw ConnectionError.invalidResponse }
    return page
  }

  private func activate(
    _ clip: EpubMediaOverlayClip, page: EpubMediaOverlayClipsPage,
    offset: Double, play: Bool
  ) async throws {
    guard let session, !isClosed else { throw NativeRecordedError.closed }
    state = .loading
    operation = UUID()
    let operation = operation
    let segment = try await reader.highlightRecorded(clip, follow: follow)
    try await audio.prepare(
      api: reader.api, bookID: reader.bookID, fileID: reader.file.id,
      clip: clip, session: session, offset: offset)
    try await position.checkSession()
    guard !isClosed, self.operation == operation else { throw CancellationError() }
    self.clip = clip
    self.segment = segment
    nextSection = page.nextSectionIndex
    previousSection = page.previousSectionIndex
    nextCursor = clip.sectionClipIndex + 1 < page.totalClips ? clip.sectionClipIndex + 1 : nil
    elapsed = audio.elapsed
    duration = audio.duration
    audio.setRate(rate)
    audio.receive = { [weak self] elapsed, ended, failure in
      guard let self, self.operation == operation, !self.isClosed else { return }
      if ended {
        self.pendingEnd = true
        if self.canControl {
          Task {
            guard self.operation == operation, self.pendingEnd else { return }
            self.pendingEnd = false
            await self.moveClip(forward: true)
          }
        }
        return
      }
      guard !self.isBusy else { return }
      self.elapsed = elapsed
      if let failure {
        Task {
          await self.fail(ConnectionError.http(502))
          self.error = failure
        }
      } else if Date().timeIntervalSince(self.lastJournalWrite) >= 1 {
        do { try self.capture() } catch {
          self.error = error.localizedDescription
          self.audio.pause()
        }
      }
      self.updateMedia()
    }
    state = .paused
    try capture()
    if play {
      try audio.play()
      state = .playing
    }
    installMedia()
    updateMedia()
    startSessionChecks()
  }

  private func capture() throws {
    guard let clip, !position.conflict.isBlocked else { return }
    elapsed = audio.elapsed
    let seconds = clip.startSeconds.map { $0 + elapsed }
    let percentage =
      segment?.percentage ?? position.saved?.percentage ?? reader.location?.percentage ?? 0
    try position.record(
      .init(
        fragment: Self.fragment(clip), sectionIndex: clip.sectionIndex,
        offsetSeconds: elapsed, positionSeconds: seconds, percentage: percentage, cfi: segment?.cfi)
    )
    lastJournalWrite = Date()
  }

  private func startSessionChecks() {
    guard sessionTask == nil else { return }
    sessionTask = Task { [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(1)) } catch { return }
        guard let self, !self.isClosed else { return }
        do { try await self.position.checkSession() } catch {
          await self.fail(error)
          return
        }
        if self.position.conflict.isBlocked {
          await self.freezeForPositionChoice()
          return
        }
        if self.pendingEnd, self.canControl {
          self.pendingEnd = false
          Task { await self.moveClip(forward: true) }
        }
        if self.isPlaying, !self.isBusy, !self.isPositionResetting,
          Date().timeIntervalSince(self.lastServerWrite) >= 15
        {
          self.lastServerWrite = Date()
          _ = await self.position.flush()
        }
      }
    }
  }

  private func installMedia() {
    guard media == nil else { return }
    media = AudioMediaController { [weak self] command in
      guard let self else { return }
      Task {
        switch command {
        case .play: if !self.isPlaying { await self.togglePlayback() }
        case .pause, .interruptionBegan, .routeRemoved: await self.pause()
        case .toggle: await self.togglePlayback()
        case .seek(let value):
          self.seekSeconds = String(value)
          await self.seek()
        case .skip(let value):
          self.seekSeconds = String(min(self.duration, max(0, self.elapsed + value)))
          await self.seek()
        case .interruptionEnded: break
        }
      }
    }
  }

  private func updateMedia() {
    media?.update(
      title: "\(title): Recorded Read Along", authors: [], track: clip?.index ?? 0,
      trackCount: (clip?.index ?? 0) + 1, position: elapsed, duration: duration,
      rate: isPlaying ? rate : 0, canControl: canControl && clip != nil, canPause: isPlaying,
      skipBack: 10, skipForward: 10)
  }

  private func fail(_ error: any Error) async {
    audio.pause()
    do { try capture() } catch { self.error = error.localizedDescription }
    operation = UUID()
    audio.close()
    media?.close()
    media = nil
    audio.releaseAudioSession()
    state = .error
    clip = nil
    segment = nil
    self.error = error.localizedDescription
    await reader.clearRecordedHighlight()
  }

  nonisolated private static func fragment(_ clip: EpubMediaOverlayClip) -> String {
    clip.textFragment.map { "\(clip.textHref)#\($0)" } ?? clip.textHref
  }

  nonisolated private static func valid(_ clip: EpubMediaOverlayClip) -> Bool {
    clip.index >= 0 && clip.sectionIndex >= 0 && clip.sectionClipIndex >= 0
      && EPUBPublicationResources.validPath(clip.textHref)
      && EPUBPublicationResources.validPath(clip.audioHref)
      && clip.audioMimeType.hasPrefix("audio/") && clip.audioSizeBytes.isFinite
      && clip.audioSizeBytes > 0 && clip.audioSizeBytes.rounded() == clip.audioSizeBytes
      && clip.audioSizeBytes < Double(Int64.max) && clip.clipBeginSeconds.isFinite
      && clip.clipBeginSeconds >= 0
      && clip.clipEndSeconds.map({ $0.isFinite && $0 >= 0 }) != false
  }
}
