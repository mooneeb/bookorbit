import AVFoundation
import Foundation
import Observation
import UIKit

struct NativeTTSVoice: Identifiable, Sendable, Equatable {
  let id: String
  let name: String
  let language: String
}

enum NativeTTSState: String {
  case idle, loading, playing, paused, error
}

@MainActor @Observable
final class NativeTTSModel {
  nonisolated static let chunkLimit = 2048
  let bookID: Int
  let title: String
  let language: String?
  let preferences: NativeTTSPreferencesModel
  let position: NativeTTSPositionModel
  let catalog: NativeTTSCatalogModel
  let server: NativeTTSServerSpeech
  let navigation = NativeTTSBlockNavigation()
  let sleepTimer = NativeTTSSleepTimerModel()
  private(set) var state = NativeTTSState.idle
  private(set) var voices: [NativeTTSVoice] = []
  private(set) var currentPassage = ""
  private(set) var currentWord = ""
  private(set) var error: String?
  private(set) var hasLoaded = false
  private(set) var isClosing = false
  private(set) var isReaderNavigating = false
  private(set) var isPositionResetting = false
  private(set) var positionResetRecovery = false
  private var positionResetGeneration = UUID()
  private(set) var isStopping = false
  private(set) var reachedEnd = false
  private var isSettingsPresented = false
  @ObservationIgnored private weak var source: (any EPUBSpeechSource)?
  @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
  @ObservationIgnored private var delegate: NativeSpeechDelegate?
  @ObservationIgnored private var heartbeat: Task<Void, Never>?
  @ObservationIgnored private var preparation: Task<Void, Never>?
  @ObservationIgnored private var highlightTask: Task<Void, Never>?
  @ObservationIgnored private var backgroundWrite: Task<Void, Never>?
  @ObservationIgnored private var observers: [NSObjectProtocol] = []
  private var generation = UUID()
  private var speechGeneration = UUID()
  private var chunk: EPUBSpeechChunk?
  private var utteranceID: ObjectIdentifier?
  private var pendingWord: NSRange?
  private var wantsPlay = false
  private var isClosed = false
  private var resumeAfterInterruption = false
  private var ownsAudioSession = false

  init(
    api: BookOrbitAPI, bookID: Int, fileID: Int, title: String, language: String?,
    source: any EPUBSpeechSource
  ) {
    self.bookID = bookID
    self.title = title
    self.language = language
    self.source = source
    preferences = NativeTTSPreferencesModel(api: api, bookID: bookID)
    position = NativeTTSPositionModel(api: api, fileID: fileID)
    catalog = NativeTTSCatalogModel(api: api)
    server = NativeTTSServerSpeech(api: api)
  }

  var isActive: Bool { state == .playing || state == .paused || state == .loading }
  var isPlaying: Bool { state == .playing }
  var canStart: Bool {
    hasLoaded && !isClosed && !isPositionResetting && !isClosing && !isReaderNavigating
      && !isStopping
      && !preferences.isSaving && !position.isSaving
      && !position.permissionBlocked && !position.conflict.isBlocked
      && state != .loading && !server.isPreviewing && !server.isLoadingPreview
      && (preferences.useServer ? effectiveServerVoice != nil : !voices.isEmpty)
  }
  var canNavigateBlock: Bool {
    canStart && (state == .playing || state == .paused) && chunk != nil
  }
  var canRetryBlock: Bool { canStart && navigation.canRetry }
  var canSetSleepTimer: Bool { canStart && isActive }
  var canStop: Bool {
    !isClosed && !isClosing && !isReaderNavigating && !isStopping
      && (isActive || server.isPreviewing || server.isLoadingPreview)
  }
  var canChangeSettings: Bool {
    hasLoaded && !isClosed && !isPositionResetting && !isClosing && !isReaderNavigating
      && !isStopping
      && !preferences.isSaving && !position.isSaving
  }
  var effectiveServerVoice: TtsVoice? {
    guard let provider = preferences.providerID, let voice = preferences.voiceID,
      catalog.loadedProviderID == provider,
      catalog.providers.contains(where: { $0.id == provider })
    else { return nil }
    return catalog.voices.first(where: { $0.id == voice })
  }
  var speechSummary: String? {
    if preferences.useServer, let voice = effectiveServerVoice {
      return
        "\(voice.providerName) · \(voice.name) · \(voice.language) · \(preferences.speed.formatted())x"
    }
    guard !preferences.useServer, let voice = effectiveVoice else { return nil }
    return "System · \(voice.name) · \(voice.language) · \(min(preferences.speed, 2).formatted())x"
  }
  var timingMessage: String? {
    guard preferences.useServer, !currentPassage.isEmpty, isActive else { return nil }
    return server.hasWordTimings
      ? "Word highlighting follows timings returned by this service."
      : "This service has no usable word timings. The spoken passage is highlighted."
  }
  var effectiveVoice: NativeTTSVoice? {
    if let selected = preferences.voiceIdentifier,
      let voice = voices.first(where: { $0.id == selected })
    {
      return voice
    }
    if let language {
      let normalized = language.replacingOccurrences(of: "_", with: "-").lowercased()
      if let exact = voices.first(where: { $0.language.lowercased() == normalized }) {
        return exact
      }
      let base = normalized.split(separator: "-").first
      if let match = voices.first(where: {
        $0.language.lowercased().split(separator: "-").first == base
      }) {
        return match
      }
    }
    let system = AVSpeechSynthesisVoice(language: nil)?.identifier
    return voices.first(where: { $0.id == system }) ?? voices.first
  }

  var voiceMessage: String? {
    if preferences.useServer {
      guard effectiveServerVoice == nil else { return nil }
      return catalog.error ?? "Choose an available server service and voice in speech settings."
    }
    guard !voices.isEmpty else {
      return "No installed system voices are available. Text to speech cannot start on this iPad."
    }
    if let selected = preferences.voiceIdentifier, !voices.contains(where: { $0.id == selected }) {
      return
        "The saved system voice is unavailable. \(effectiveVoice?.name ?? "An installed voice") will be used."
    }
    return nil
  }

  var rateMessage: String? {
    guard !preferences.useServer, preferences.speed > 2 else { return nil }
    return
      "The account speed is \(preferences.speed.formatted())x. System speech is limited to 2x on this iPad."
  }

  func open() async {
    guard !isClosed, !hasLoaded, heartbeat == nil else { return }
    error = nil
    refreshVoices()
    async let settings: Void = preferences.load()
    async let progress: Void = position.load()
    _ = await (settings, progress)
    guard !isClosed, !Task.isCancelled else { return }
    await catalog.loadProviders()
    if let provider = preferences.providerID, preferences.useServer {
      await catalog.loadVoices(providerID: provider)
    }
    guard !isClosed, !Task.isCancelled else { return }
    hasLoaded = preferences.hasLoaded && position.hasLoaded
    guard hasLoaded else {
      state = .error
      error = preferences.error ?? position.message ?? "Speech settings could not be loaded."
      return
    }
    observeAudioSession()
    state = .idle
    heartbeat = Task { [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(2)) } catch { return }
        guard let self, !self.isClosed else { return }
        do {
          try await self.position.checkSession()
          if !self.isPositionResetting, self.position.hasPendingSave, !self.position.isSaving {
            _ = await self.position.flush()
            if self.position.permissionBlocked { await self.fail(ConnectionError.denied) }
          }
        } catch {
          await self.fail(error)
          return
        }
      }
    }
  }

  func retry() async {
    guard !isClosed, !isPositionResetting, !isClosing, !isReaderNavigating, !isStopping else {
      return
    }
    if !hasLoaded {
      await open()
    } else {
      error = nil
      state = .idle
      _ = await position.flush()
    }
  }

  func startFromCurrentPosition() async { await start(fromCFI: nil) }

  func resumeSavedPosition() async {
    guard let saved = position.savedPosition else { return }
    await start(fromCFI: saved.cfi)
  }

  func previousBlock() async {
    guard canNavigateBlock, let chunk else { return }
    await navigateBlock(
      NativeTTSBlockRequest(direction: .previous, chunk: chunk),
      resolved: navigation.previousChunk(from: chunk))
  }

  func nextBlock() async {
    guard canNavigateBlock, let chunk else { return }
    await navigateBlock(NativeTTSBlockRequest(direction: .next, chunk: chunk))
  }

  func retryBlockNavigation() async {
    guard canRetryBlock, let request = navigation.request else { return }
    await navigateBlock(request, resolved: navigation.resolvedChunk)
  }

  func cancelBlockNavigation() async {
    guard navigation.isLoading else { return }
    await stop(preservingSleepTimer: true)
    guard !isClosed else { return }
    state = .paused
  }

  func startSleepTimer(minutes: Int) {
    guard canSetSleepTimer else { return }
    sleepTimer.start(minutes: minutes) { [weak self] in await self?.expireSleepTimer() }
  }

  private func expireSleepTimer() async {
    guard !isClosed, !isPositionResetting else { return }
    resumeAfterInterruption = false
    wantsPlay = false
    if state == .playing || state == .loading { await pause() }
  }

  private func navigateBlock(
    _ request: NativeTTSBlockRequest, resolved: EPUBSpeechChunk? = nil
  ) async {
    guard canStart else { return }
    let expirationCount = sleepTimer.expirationCount
    let saved = await stopAndSave(preservingSleepTimer: true)
    guard !isClosed, !isPositionResetting, saved else { return }
    guard expirationCount == sleepTimer.expirationCount else {
      state = .paused
      return
    }
    navigation.begin(request, resolved: resolved)
    reachedEnd = false
    error = nil
    state = .loading
    wantsPlay = true
    let playbackGeneration = generation
    preparation = Task { [weak self] in
      await self?.prepareBlockNavigation(request, generation: playbackGeneration)
    }
    await preparation?.value
  }

  private func prepareBlockNavigation(
    _ request: NativeTTSBlockRequest, generation playbackGeneration: UUID
  ) async {
    do {
      try await position.checkSession()
      guard let source else { throw NativeTTSError.readerClosed }
      let value: EPUBSpeechChunk?
      if let resolved = navigation.resolvedChunk {
        value = resolved
      } else if request.direction == .previous {
        value = try await source.previousSpeechChunk(
          fromCFI: request.chunk.cfi, maximumUTF16Length: Self.chunkLimit)
      } else if let next = request.chunk.nextCFI {
        value = try await source.speechChunk(
          fromCFI: next, maximumUTF16Length: Self.chunkLimit)
      } else {
        value = nil
      }
      try Task.checkCancellation()
      try await position.checkSession()
      guard playbackGeneration == generation, !isClosed, wantsPlay else { return }
      guard let value else {
        navigation.clearRequest()
        await finishBook()
        return
      }
      guard value.isValid else { throw ConnectionError.invalidResponse }
      navigation.resolve(value)
      try await speakChunk(value, generation: playbackGeneration)
      guard playbackGeneration == generation, !isClosed, wantsPlay else { return }
      navigation.completed(
        atBeginning: request.direction == .previous && value.cfi == request.chunk.cfi)
    } catch is CancellationError {
    } catch {
      if playbackGeneration == generation, !isClosed { await fail(error) }
    }
  }

  func togglePlayback() async {
    guard !isClosed, !isPositionResetting, !isClosing, !isReaderNavigating, !isStopping else {
      return
    }
    resumeAfterInterruption = false
    if state == .playing || state == .loading {
      await pause()
    } else if state == .paused, preferences.useServer, server.isPrepared {
      let request = generation
      let expirationCount = sleepTimer.expirationCount
      do {
        try await position.checkSession()
        guard request == generation, !isClosed,
          expirationCount == sleepTimer.expirationCount
        else { return }
        try activateAudioSession()
        try await server.play()
        guard request == generation, !isClosed else { return }
        guard expirationCount == sleepTimer.expirationCount else {
          server.pause()
          return
        }
        wantsPlay = true
        state = .playing
      } catch { if request == generation, !isClosed { await fail(error) } }
    } else if state == .paused, utteranceID != nil, synthesizer.isPaused {
      let request = generation
      let expirationCount = sleepTimer.expirationCount
      do {
        try await position.checkSession()
        guard request == generation, !isClosed,
          expirationCount == sleepTimer.expirationCount
        else { return }
        try activateAudioSession()
        guard synthesizer.continueSpeaking() else {
          throw NativeTTSError.cannotResume
        }
        wantsPlay = true
        state = .playing
      } catch { if request == generation, !isClosed { await fail(error) } }
    } else if let saved = position.savedPosition {
      await start(fromCFI: saved.cfi)
    } else {
      await start(fromCFI: nil)
    }
  }

  func pause() async {
    guard !isClosed, !isClosing, !isReaderNavigating, !isStopping,
      state == .playing || state == .loading
    else {
      return
    }
    resumeAfterInterruption = false
    wantsPlay = false
    if preferences.useServer, state == .loading {
      await stop(preservingSleepTimer: true)
      guard !isClosed else { return }
      state = .paused
      return
    }
    if preferences.useServer, server.isPrepared {
      server.pause()
    } else if utteranceID != nil {
      if !synthesizer.pauseSpeaking(at: .immediate) {
        await stop(preservingSleepTimer: true)
        guard !isClosed else { return }
        state = .paused
        return
      }
    } else {
      await stop(preservingSleepTimer: true)
      guard !isClosed else { return }
      state = .paused
      return
    }
    state = .paused
    await highlightTask?.value
    _ = await position.flush()
  }

  func stop(preservingSleepTimer: Bool = false) async {
    guard !isClosed, !isStopping else { return }
    isStopping = true
    defer { isStopping = false }
    wantsPlay = false
    resumeAfterInterruption = false
    if !preservingSleepTimer { sleepTimer.cancel() }
    let preparing = preparation
    let highlighting = highlightTask
    invalidatePlayback()
    navigation.clearRequest()
    await source?.clearSpeechHighlight()
    await preparing?.value
    await highlighting?.value
    guard !isClosed else { return }
    state = .idle
    _ = await position.flush()
    await source?.clearSpeechHighlight()
    deactivateAudioSession()
  }

  func stopAndSave(preservingSleepTimer: Bool = false) async -> Bool {
    guard !isClosed, !isStopping else { return false }
    await stop(preservingSleepTimer: preservingSleepTimer)
    return !isClosed && !position.hasPendingSave && !position.permissionBlocked
  }

  func saveSettings(
    speed: Double, voiceIdentifier: String?, providerID: String?, voiceID: String?,
    useServer: Bool, asDefault: Bool
  ) async -> Bool {
    guard canChangeSettings,
      !useServer
        || (providerID != nil && voiceID != nil
          && catalog.contains(providerID: providerID ?? "", voiceID: voiceID ?? "")),
      await stopAndSave()
    else { return false }
    return await preferences.save(
      speed: speed, voiceIdentifier: voiceIdentifier, providerID: providerID, voiceID: voiceID,
      useServer: useServer, asDefault: asDefault)
  }

  func previewVoice(providerID: String, voiceID: String) async {
    guard canChangeSettings, catalog.contains(providerID: providerID, voiceID: voiceID),
      await stopAndSave()
    else { return }
    do {
      try await position.checkSession()
      try activateAudioSession()
      await server.previewVoice(providerID: providerID, voiceID: voiceID)
    } catch { await fail(error) }
  }

  func stopPreview() {
    server.stop()
    deactivateAudioSession()
  }

  func beginSettings() async -> Bool {
    guard canChangeSettings, await stopAndSave() else { return false }
    isSettingsPresented = true
    return true
  }

  func settingsClosed() async {
    isSettingsPresented = false
    stopPreview()
    guard !isClosed, preferences.useServer, let provider = preferences.providerID,
      catalog.loadedProviderID != provider
    else { return }
    await catalog.loadVoices(providerID: provider)
  }

  func navigateReader(_ action: @MainActor () async -> Void) async {
    if positionResetRecovery, !isClosed {
      await action()
      return
    }
    guard !isClosed, !isPositionResetting, !isClosing, !isReaderNavigating, !isStopping,
      !preferences.isSaving
    else {
      return
    }
    isReaderNavigating = true
    defer { isReaderNavigating = false }
    await stop()
    await action()
  }

  func useDefaultSettings() async -> Bool {
    guard canChangeSettings, await stopAndSave() else { return false }
    let saved = await preferences.useDefaults()
    if saved, let provider = preferences.providerID, preferences.useServer {
      await catalog.loadVoices(providerID: provider)
    }
    return saved
  }

  func foreground() async {
    guard !isClosed, !isPositionResetting else { return }
    refreshVoices()
    do {
      try await position.checkSession()
      await sleepTimer.foreground()
      await position.refresh()
      await describePositionConflict()
      if position.conflict.isBlocked { await stop() }
      if !isActive, !isSettingsPresented {
        await catalog.loadProviders()
        if let provider = preferences.providerID, preferences.useServer {
          await catalog.loadVoices(providerID: provider)
        }
      }
    } catch { await fail(error) }
  }

  func background() {
    guard !isClosed, !isPositionResetting, hasLoaded, backgroundWrite == nil else { return }
    sleepTimer.background()
    if server.isPreviewing || server.isLoadingPreview { stopPreview() }
    var identifier = UIBackgroundTaskIdentifier.invalid
    identifier = UIApplication.shared.beginBackgroundTask(withName: "Save speech position") {
      [weak self] in
      Task { @MainActor in self?.backgroundWrite?.cancel() }
    }
    backgroundWrite = Task { [weak self] in
      if let self {
        await self.highlightTask?.value
        _ = await self.position.flush()
      }
      if identifier != .invalid { UIApplication.shared.endBackgroundTask(identifier) }
      self?.backgroundWrite = nil
    }
  }

  func finish() async -> Bool {
    guard !isClosed, !isClosing, !isReaderNavigating, !isStopping,
      !preferences.isSaving, !position.isSaving
    else {
      return false
    }
    isClosing = true
    defer { isClosing = false }
    await stop()
    let saved = position.hasPendingSave ? await position.flush() : true
    return saved
  }

  func describePositionConflict() async {
    guard position.conflict.isBlocked, let reader = source as? EPUBReaderModel else { return }
    let identity = position.conflict.identity
    var localText: String?
    var remoteText: String?
    if let target = position.localTarget { localText = try? await reader.describePosition(target) }
    if let target = position.remoteTarget {
      remoteText = try? await reader.describePosition(target)
    }
    position.conflict.describe(local: localText, remote: remoteText, identity: identity)
  }

  func choosePosition(local: Bool) async {
    guard !isClosed, !isPositionResetting, !isStopping, position.conflict.isBlocked else { return }
    await stop()
    guard await position.choosePosition(local: local), !isClosed else {
      await describePositionConflict()
      return
    }
    await resumeSavedPosition()
  }

  var canResetPosition: Bool {
    hasLoaded && !isClosed && (!isPositionResetting || positionResetRecovery)
      && !isClosing && !isReaderNavigating && !isStopping && !preferences.isSaving
  }

  func beginPositionReset() async throws {
    guard !isClosed else { throw CancellationError() }
    let request = UUID()
    positionResetGeneration = request
    isPositionResetting = true
    positionResetRecovery = false
    sleepTimer.cancel()
    wantsPlay = false
    resumeAfterInterruption = false
    try await NativePositionResetWait.drain {
      self.isStopping || self.isReaderNavigating || self.preferences.isSaving
    }
    guard request == positionResetGeneration, isPositionResetting else { throw CancellationError() }
    await stop()
    await backgroundWrite?.value
    try await NativePositionResetWait.drain { self.position.isSaving || self.position.isResolving }
    guard request == positionResetGeneration, isPositionResetting else { throw CancellationError() }
    navigation.reset()
    position.suspendForReset(true)
    try Task.checkCancellation()
  }

  func acknowledgePositionReset() {
    position.acknowledgeReset()
    currentPassage = ""
    currentWord = ""
    reachedEnd = false
  }

  func endPositionReset(_ reset: NativePositionResetModel) async {
    if reset.didClearLocalPosition {
      position.suspendForReset(false)
      await position.load()
      isPositionResetting = !position.hasLoaded
    } else if !reset.didAttempt {
      position.suspendForReset(false)
      isPositionResetting = false
    }
    positionResetRecovery = isPositionResetting
    if isPositionResetting {
      error = "Speech reset is unconfirmed. Clear saved speech position again to check or retry."
    } else {
      error = nil
    }
  }

  func cancelPositionReset() {
    positionResetGeneration = UUID()
    isPositionResetting = false
    positionResetRecovery = false
    position.suspendForReset(false)
  }

  func close() {
    guard !isClosed else { return }
    isClosed = true
    wantsPlay = false
    sleepTimer.close()
    navigation.reset()
    invalidatePlayback()
    heartbeat?.cancel()
    heartbeat = nil
    backgroundWrite?.cancel()
    backgroundWrite = nil
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers.removeAll()
    synthesizer.delegate = nil
    delegate = nil
    preferences.close()
    position.close()
    catalog.close()
    server.close()
    deactivateAudioSession()
  }

  private func start(fromCFI: String?) async {
    guard canStart else { return }
    let expirationCount = sleepTimer.expirationCount
    guard await stopAndSave(preservingSleepTimer: true) else { return }
    guard expirationCount == sleepTimer.expirationCount else {
      state = .paused
      return
    }
    navigation.reset()
    wantsPlay = false
    utteranceID = nil
    synthesizer.stopSpeaking(at: .immediate)
    await highlightTask?.value
    invalidatePlayback()
    reachedEnd = false
    error = nil
    state = .loading
    wantsPlay = true
    let request = generation
    preparation = Task { [weak self] in await self?.prepare(fromCFI: fromCFI, generation: request) }
    await preparation?.value
  }

  private func prepare(fromCFI: String?, generation request: UUID) async {
    do {
      try await position.checkSession()
      guard let source else { throw NativeTTSError.readerClosed }
      let value = try await source.speechChunk(
        fromCFI: fromCFI, maximumUTF16Length: Self.chunkLimit)
      try Task.checkCancellation()
      try await position.checkSession()
      guard request == generation, !isClosed, wantsPlay else { return }
      guard let value else {
        await finishBook()
        return
      }
      guard value.isValid else { throw ConnectionError.invalidResponse }
      navigation.clearRequest()
      try await speakChunk(value, generation: request)
    } catch is CancellationError {
    } catch { if request == generation, !isClosed { await fail(error) } }
  }

  private func speakChunk(_ value: EPUBSpeechChunk, generation request: UUID) async throws {
    guard let source, value.isValid else { throw ConnectionError.invalidResponse }
    chunk = value
    currentPassage = value.text
    currentWord = ""
    navigation.remember(value)
    let anchor = try await source.highlightSpeech(
      chunkCFI: value.cfi, utf16Range: NSRange(location: 0, length: value.text.utf16.count))
    try Task.checkCancellation()
    try await position.checkSession()
    guard request == generation, !isClosed, wantsPlay else { return }
    try await position.record(anchor)
    guard request == generation, !isClosed, wantsPlay else { return }
    if preferences.useServer {
      try await prepareServer(value, generation: request)
      return
    }
    refreshVoices()
    guard let effectiveVoice, let voice = AVSpeechSynthesisVoice(identifier: effectiveVoice.id)
    else { throw NativeTTSError.noInstalledVoice }
    try activateAudioSession()
    let utterance = AVSpeechUtterance(string: value.text)
    utterance.voice = voice
    utterance.rate = min(
      AVSpeechUtteranceMaximumSpeechRate,
      max(
        AVSpeechUtteranceMinimumSpeechRate,
        AVSpeechUtteranceDefaultSpeechRate * Float(preferences.speed)))
    utteranceID = ObjectIdentifier(utterance)
    let callbackGeneration = UUID()
    speechGeneration = callbackGeneration
    delegate = NativeSpeechDelegate { [weak self] event in
      Task { @MainActor in self?.receive(event, generation: callbackGeneration) }
    }
    synthesizer.delegate = delegate
    synthesizer.speak(utterance)
  }

  private func finishBook() async {
    reachedEnd = true
    wantsPlay = false
    resumeAfterInterruption = false
    state = .idle
    _ = await position.flush()
    await source?.clearSpeechHighlight()
    deactivateAudioSession()
  }

  private func prepareServer(_ value: EPUBSpeechChunk, generation request: UUID) async throws {
    guard let voice = effectiveServerVoice, let source else {
      throw NativeTTSError.unavailableServerVoice
    }
    let callbackGeneration = UUID()
    speechGeneration = callbackGeneration
    try await server.prepare(
      chunk: value, providerID: voice.providerId, voiceID: voice.id, speed: preferences.speed
    ) { [weak self] event in
      Task { @MainActor in self?.receiveServer(event, generation: callbackGeneration) }
    }
    try Task.checkCancellation()
    try await position.checkSession()
    guard request == generation, !isClosed, wantsPlay else { return }
    if !server.hasWordTimings {
      let anchor = try await source.highlightSpeech(
        chunkCFI: value.cfi, utf16Range: NSRange(location: 0, length: value.text.utf16.count))
      try Task.checkCancellation()
      guard request == generation, !isClosed, wantsPlay else { return }
      try await position.record(anchor)
    }
    try await position.checkSession()
    guard request == generation, !isClosed, wantsPlay else { return }
    try activateAudioSession()
    try await server.play()
    guard request == generation, !isClosed, wantsPlay else { return }
    state = .playing
  }

  private func receiveServer(_ event: NativeTTSServerEvent, generation request: UUID) {
    guard !isClosed, request == speechGeneration, preferences.useServer else { return }
    switch event {
    case .word(let range):
      guard wantsPlay, state == .playing, let chunk, validRange(range, text: chunk.text) else {
        return
      }
      pendingWord = range
      if highlightTask == nil {
        let request = generation
        highlightTask = Task { [weak self] in await self?.processWords(generation: request) }
      }
    case .finished:
      guard wantsPlay else { return }
      let request = generation
      preparation = Task { [weak self] in await self?.finishedChunk(generation: request) }
    case .failed:
      Task { [weak self] in
        guard let self, request == self.speechGeneration, !self.isClosed else { return }
        await self.fail(NativeTTSError.serverAudioFailed)
      }
    }
  }

  private func receive(_ event: NativeSpeechEvent, generation request: UUID) {
    guard !isClosed, request == speechGeneration else { return }
    switch event {
    case .started(let id), .continued(let id):
      guard id == utteranceID else { return }
      if wantsPlay { state = .playing }
    case .paused(let id):
      guard id == utteranceID else { return }
      state = .paused
    case .word(let id, let range):
      guard id == utteranceID, wantsPlay, state == .playing,
        let chunk, validRange(range, text: chunk.text)
      else { return }
      pendingWord = range
      if highlightTask == nil {
        let request = generation
        highlightTask = Task { [weak self] in await self?.processWords(generation: request) }
      }
    case .finished(let id):
      guard id == utteranceID, wantsPlay else { return }
      let request = generation
      preparation = Task { [weak self] in await self?.finishedChunk(generation: request) }
    case .cancelled(let id):
      guard id == utteranceID else { return }
      utteranceID = nil
      wantsPlay = false
      state = .paused
    }
  }

  private func processWords(generation request: UUID) async {
    defer { if request == generation { highlightTask = nil } }
    while let range = pendingWord, let chunk, let source, !isClosed, request == generation {
      pendingWord = nil
      do {
        try await position.checkSession()
        let anchor = try await source.highlightSpeech(chunkCFI: chunk.cfi, utf16Range: range)
        try Task.checkCancellation()
        guard request == generation, !isClosed else { return }
        try await position.record(anchor)
        guard request == generation, !isClosed else { return }
        currentWord = (chunk.text as NSString).substring(with: range)
      } catch is CancellationError { return } catch {
        if request == generation, !isClosed { await fail(error) }
        return
      }
    }
  }

  private func finishedChunk(generation request: UUID) async {
    await highlightTask?.value
    guard !isClosed, request == generation, let chunk else { return }
    utteranceID = nil
    if let next = chunk.nextCFI {
      do {
        try await position.record(TtsPosition(cfi: next, chapterIndex: nil))
      } catch {
        if request == generation, !isClosed, !Task.isCancelled { await fail(error) }
        return
      }
      guard request == generation, !isClosed, !Task.isCancelled else { return }
      if wantsPlay {
        state = .loading
        await prepare(fromCFI: next, generation: request)
      } else {
        state = .paused
      }
    } else {
      await finishBook()
    }
  }

  private func invalidatePlayback() {
    generation = UUID()
    speechGeneration = UUID()
    preparation?.cancel()
    preparation = nil
    highlightTask?.cancel()
    highlightTask = nil
    pendingWord = nil
    utteranceID = nil
    synthesizer.stopSpeaking(at: .immediate)
    server.stop()
    chunk = nil
    currentWord = ""
  }

  private func fail(_ error: any Error) async {
    wantsPlay = false
    resumeAfterInterruption = false
    navigation.failed(error)
    if let connection = error as? ConnectionError {
      switch connection {
      case .expiredSession, .denied:
        sleepTimer.cancel()
        navigation.reset()
      default: break
      }
    }
    invalidatePlayback()
    let request = generation
    state = .loading
    deactivateAudioSession()
    await source?.clearSpeechHighlight()
    guard request == generation, !isClosed else { return }
    state = .error
    self.error = error.localizedDescription
  }

  private func refreshVoices() {
    voices = AVSpeechSynthesisVoice.speechVoices()
      .filter { !$0.voiceTraits.contains(.isPersonalVoice) }
      .map { NativeTTSVoice(id: $0.identifier, name: $0.name, language: $0.language) }
      .sorted { ($0.language, $0.name, $0.id) < ($1.language, $1.name, $1.id) }
  }

  private func validRange(_ range: NSRange, text: String) -> Bool {
    range.location != NSNotFound && range.location >= 0 && range.length > 0
      && range.location <= text.utf16.count && range.length <= text.utf16.count - range.location
      && Range(range, in: text) != nil
  }

  private func activateAudioSession() throws {
    try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
    try AVAudioSession.sharedInstance().setActive(true)
    ownsAudioSession = true
  }

  private func deactivateAudioSession() {
    guard ownsAudioSession else { return }
    ownsAudioSession = false
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }

  private func observeAudioSession() {
    observers.append(
      NotificationCenter.default.addObserver(
        forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
      ) { [weak self] notification in
        let type = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?
          .uintValue
        let options =
          (notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? NSNumber)?.uintValue ?? 0
        Task { @MainActor in
          guard let self, !self.isClosed else { return }
          if type == AVAudioSession.InterruptionType.began.rawValue {
            if self.server.isPreviewing || self.server.isLoadingPreview { self.stopPreview() }
            let resume = self.isPlaying
            let expirationCount = self.sleepTimer.expirationCount
            await self.pause()
            self.resumeAfterInterruption =
              !self.isPositionResetting && resume
              && expirationCount == self.sleepTimer.expirationCount
          } else if type == AVAudioSession.InterruptionType.ended.rawValue {
            await self.sleepTimer.refreshElapsed()
            let resume =
              self.resumeAfterInterruption
              && AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume)
            self.resumeAfterInterruption = false
            if resume { await self.togglePlayback() }
          }
        }
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
        Task { @MainActor in
          if self?.server.isPreviewing == true || self?.server.isLoadingPreview == true {
            self?.stopPreview()
          }
          self?.resumeAfterInterruption = false
          await self?.pause()
        }
      })
  }
}

enum NativeTTSError: LocalizedError {
  case noInstalledVoice, cannotResume, readerClosed, unavailableServerVoice, serverAudioFailed

  var errorDescription: String? {
    switch self {
    case .noInstalledVoice: "The selected system speech voice is no longer available."
    case .cannotResume: "System speech could not resume. Stop and resume from the saved passage."
    case .readerClosed: "The ebook reader has closed. Reopen it to use text to speech."
    case .unavailableServerVoice:
      "The saved server speech service or voice is unavailable. Choose an enabled service and voice."
    case .serverAudioFailed:
      "Server speech audio could not play. Stop and resume from the saved passage."
    }
  }
}
