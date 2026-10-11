import Foundation
import Observation
import SwiftUI

struct NativeReadingPlaybackEvidence {
  let isPlaying: Bool
  var positionSeconds: Double? = nil
  var rate: Double = 1
}

private struct RecordedNativeActivity: Codable, Equatable {
  let sessionID: String
  let fileID: Int
  let type: String
  let attemptID: Int?
  let startedAt: Date
  var endedAt: Date
  var seconds: Double
  let startProgress: Double?
  var endProgress: Double?

  var payload: SaveReadingSessionPayload {
    var value = SaveReadingSessionPayload(
      sessionId: sessionID, startedAt: Self.timestamp(startedAt), endedAt: Self.timestamp(endedAt),
      durationSeconds: Int(seconds.rounded(.down)))
    value.source = "ios"
    value.sessionType = type
    value.endProgress = endProgress
    if let startProgress, let endProgress { value.progressDelta = endProgress - startProgress }
    return value
  }

  private static func timestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }
}

@MainActor @Observable
final class NativeReadingActivityCoordinator {
  @ObservationIgnored private static var coordinators: [String: NativeReadingActivityCoordinator] =
    [:]
  private struct Channel {
    var fileID: Int
    var type: String
    var attemptID: Int?
    var progress: Double?
    var active: Bool
    var interaction: Date
    var playback: (@MainActor () -> NativeReadingPlaybackEvidence)?
  }
  private struct State: Codable {
    var pending: [RecordedNativeActivity] = []
    var recovery: [RecordedNativeActivity] = []

    init() {}
    private enum CodingKeys: CodingKey { case pending, recovery }
    init(from decoder: any Decoder) throws {
      let values = try decoder.container(keyedBy: CodingKeys.self)
      pending = try values.decodeIfPresent([RecordedNativeActivity].self, forKey: .pending) ?? []
      recovery = try values.decodeIfPresent([RecordedNativeActivity].self, forKey: .recovery) ?? []
    }
  }
  private let namespace: String
  private let journal: NativeReadingRecordJournal
  private var state: State
  private var channels: [UUID: Channel] = [:]
  private var current: RecordedNativeActivity?
  private var lastPlaybackPosition: Double?
  @ObservationIgnored private var lastSample = ContinuousClock.now
  private var isFlushing = false
  private var failedToPersist = false
  private(set) var error: String?

  var recoveryItems: [NativeReadingRecoveryItem] {
    state.recovery.map {
      NativeReadingRecoveryItem(
        id: $0.sessionID, title: "\($0.type.capitalized) session for file \($0.fileID)",
        reason:
          "\(Int($0.seconds)) seconds beginning \($0.startedAt.formatted()). The book or reading attempt is unavailable."
      )
    }
  }

  func recoveryData() throws -> Data {
    let records: [[String: Any]] = try state.recovery.map {
      [
        "fileId": $0.fileID, "attemptId": $0.attemptID.map { $0 as Any } ?? NSNull(),
        "session": try JSONSerialization.jsonObject(with: JSONEncoder().encode($0.payload)),
      ]
    }
    return try JSONSerialization.data(withJSONObject: records)
  }

  private init(namespace: String) throws {
    self.namespace = namespace
    journal = try NativeReadingRecordJournal(namespace: namespace, key: "activity")
    state = try journal.read(State.self) ?? State()
    guard state.pending.count + state.recovery.count <= 512 else {
      throw OfflineStorageError.storageLimit
    }
    if !state.recovery.isEmpty {
      error =
        "Some reading sessions are retained on this iPad because their books or reading attempts are unavailable."
    }
  }

  static func open(api: BookOrbitAPI) async throws -> NativeReadingActivityCoordinator {
    let namespace = try await api.storageNamespace()
    if let current = coordinators[namespace] { return current }
    let current = try NativeReadingActivityCoordinator(namespace: namespace)
    coordinators[namespace] = current
    return current
  }

  static func flush(api: BookOrbitAPI) async throws {
    let current = try await open(api: api)
    try await current.flushPending(api: api)
    try await NativePersonalReadingOutbox.flush(api: api)
    try await NativeReadingAttemptOutbox.flush(api: api)
  }

  static func disconnect(api: BookOrbitAPI) async {
    guard let namespace = try? await api.storageNamespace(), let current = coordinators[namespace]
    else { return }
    current.sample()
    current.channels.removeAll()
    current.current = nil
    coordinators.removeValue(forKey: namespace)
  }

  func update(
    id: UUID, fileID: Int, type: String, attemptID: Int?, progress: Double?, active: Bool,
    interaction: Bool, playback: (@MainActor () -> NativeReadingPlaybackEvidence)? = nil
  ) {
    guard fileID > 0, ["read", "tts", "listen"].contains(type) else { return }
    sample()
    let percentage = progress.flatMap { $0.isFinite ? min(100, max(0, $0)) : nil }
    let previous = channels[id]
    let changed = previous?.progress != percentage || previous?.active != active
    channels[id] = Channel(
      fileID: fileID, type: type, attemptID: attemptID, progress: percentage, active: active,
      interaction: interaction || changed ? Date() : previous?.interaction ?? Date(),
      playback: playback)
    sample()
  }

  func remove(id: UUID) {
    sample()
    channels.removeValue(forKey: id)
    sample()
  }

  func sample() {
    let now = Date()
    let sampledAt = ContinuousClock.now
    let candidates = channels.values.filter {
      $0.active && ($0.playback?().isPlaying ?? true)
        && ($0.type != "read" || now.timeIntervalSince($0.interaction) < 120)
    }
    let selected = candidates.sorted {
      if ($0.type == "read") != ($1.type == "read") { return $0.type != "read" }
      return $0.interaction > $1.interaction
    }.first
    defer { lastSample = sampledAt }
    if var previous = current {
      let interval = lastSample.duration(to: sampledAt).components
      let elapsed = max(0, Double(interval.seconds) + Double(interval.attoseconds) / 1e18)
      var played = min(15, elapsed)
      previous.endedAt = now
      if let matching = channels.values.first(where: {
        $0.fileID == previous.fileID && $0.type == previous.type
          && $0.attemptID == previous.attemptID
      }) {
        previous.endProgress = matching.progress
        if let evidence = matching.playback?() {
          if let position = evidence.positionSeconds, let lastPlaybackPosition,
            position.isFinite, evidence.rate.isFinite, evidence.rate > 0
          {
            played = min(elapsed, max(0, position - lastPlaybackPosition) / evidence.rate)
          } else {
            played = evidence.isPlaying ? elapsed : 0
          }
          lastPlaybackPosition = evidence.positionSeconds
        }
      }
      previous.seconds += played
      do {
        var next = state
        if let index = next.pending.firstIndex(where: { $0.sessionID == previous.sessionID }) {
          next.pending[index] = previous
        } else {
          guard next.pending.count + next.recovery.count < 512 else {
            throw OfflineStorageError.storageLimit
          }
          next.pending.append(previous)
        }
        try journal.save(next)
        state = next
        current = previous
        failedToPersist = false
      } catch {
        failedToPersist = true
        self.error = "Reading time could not be saved on this iPad. \(error.localizedDescription)"
      }
      if selected?.fileID != previous.fileID || selected?.type != previous.type
        || selected?.attemptID != previous.attemptID
        || now.timeIntervalSince(previous.startedAt) >= 900
      {
        current = nil
      }
    }
    if current == nil, let selected {
      lastPlaybackPosition = selected.playback?().positionSeconds
      current = RecordedNativeActivity(
        sessionID: UUID().uuidString, fileID: selected.fileID, type: selected.type,
        attemptID: selected.attemptID,
        startedAt: now, endedAt: now, seconds: 0, startProgress: selected.progress,
        endProgress: selected.progress)
    }
  }

  private func flushPending(api: BookOrbitAPI) async throws {
    guard !isFlushing else { return }
    isFlushing = true
    defer { isFlushing = false }
    let generation = try await api.authenticatedSessionGeneration()
    for snapshot in state.pending.prefix(64) {
      guard try await api.storageNamespace() == namespace else {
        throw ConnectionError.expiredSession
      }
      if snapshot.seconds < 10 {
        if current?.sessionID == snapshot.sessionID { continue }
      } else {
        do {
          try await api.saveNativeReadingSession(
            fileID: snapshot.fileID, payload: snapshot.payload, attemptID: snapshot.attemptID,
            session: generation)
        } catch {
          let requiresRecovery: Bool
          switch error {
          case ConnectionError.http(400), ConnectionError.http(404), ConnectionError.denied:
            requiresRecovery = true
          default: requiresRecovery = false
          }
          if requiresRecovery {
            var next = state
            next.pending.removeAll { $0 == snapshot }
            next.recovery.removeAll { $0.sessionID == snapshot.sessionID }
            next.recovery.append(snapshot)
            try journal.save(next)
            state = next
            continue
          }
          throw error
        }
      }
      guard try await api.storageNamespace() == namespace else {
        throw ConnectionError.expiredSession
      }
      var next = state
      next.pending.removeAll { $0 == snapshot }
      try journal.save(next)
      state = next
    }
    if !failedToPersist {
      error =
        state.recovery.isEmpty
        ? nil
        : "Some reading sessions are retained on this iPad because their books or reading attempts are unavailable."
    }
  }
}

private struct NativeReadingActivityModifier: ViewModifier {
  let api: BookOrbitAPI
  let fileID: Int
  let type: String
  let progress: Double?
  let active: Bool
  let playback: (@MainActor () -> NativeReadingPlaybackEvidence)?
  @Environment(\.scenePhase) private var scenePhase
  @State private var id = UUID()
  @State private var coordinator: NativeReadingActivityCoordinator?
  @State private var syncError: String?
  @State private var attemptID: Int?
  @State private var captureReady = false

  private var isActive: Bool { active && (type != "read" || scenePhase == .active) }

  func body(content: Content) -> some View {
    content
      .simultaneousGesture(TapGesture().onEnded { pulse() })
      .task(id: "\(fileID)|\(type)|\(isActive)") {
        do {
          coordinator = try await NativeReadingActivityCoordinator.open(api: api)
          captureReady = false
          guard isActive else {
            update()
            return
          }
          attemptID = nil
          if !(await api.isOffline) {
            attemptID = try? await api.readingSessionContext(fileID: fileID).attemptId
          }
          try Task.checkCancellation()
          captureReady = true
          update()
          while !Task.isCancelled {
            coordinator?.sample()
            try await Task.sleep(for: .seconds(5))
          }
        } catch is CancellationError {
        } catch { syncError = error.localizedDescription }
      }
      .task(id: "sync|\(fileID)|\(type)|\(isActive)") {
        guard isActive else { return }
        while !Task.isCancelled {
          do {
            try await NativeReadingActivityCoordinator.flush(api: api)
            syncError = nil
          } catch is CancellationError {
            return
          } catch {
            syncError = "Reading time is saved on this iPad and will retry when connected."
          }
          do { try await Task.sleep(for: .seconds(5)) } catch { return }
        }
      }
      .onChange(of: isActive) { if !isActive { update() } }
      .onChange(of: progress) { pulse() }
      .onDisappear {
        coordinator?.remove(id: id)
        Task { try? await NativeReadingActivityCoordinator.flush(api: api) }
      }
      .overlay(alignment: .bottom) {
        if isActive, let message = coordinator?.error ?? syncError {
          Text(message).font(.caption).padding(8).background(.regularMaterial)
            .accessibilityIdentifier("readingActivitySyncFeedback")
        }
      }
  }

  private func update() {
    coordinator?.update(
      id: id, fileID: fileID, type: type, attemptID: attemptID, progress: progress,
      active: isActive && captureReady, interaction: false, playback: playback)
  }

  private func pulse() {
    coordinator?.update(
      id: id, fileID: fileID, type: type, attemptID: attemptID, progress: progress,
      active: isActive && captureReady, interaction: true, playback: playback)
  }
}

extension View {
  func readingActivity(
    api: BookOrbitAPI, fileID: Int, type: String, progress: Double?, active: Bool,
    playback: (@MainActor () -> NativeReadingPlaybackEvidence)? = nil
  ) -> some View {
    modifier(
      NativeReadingActivityModifier(
        api: api, fileID: fileID, type: type, progress: progress, active: active,
        playback: playback))
  }
}
