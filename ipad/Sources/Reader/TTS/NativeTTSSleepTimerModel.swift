import Foundation
import Observation

@MainActor @Observable
final class NativeTTSSleepTimerModel {
  static let presets = [5, 10, 15, 30, 60]
  private(set) var activeMinutes: Int?
  private(set) var remainingSeconds: Int?
  private(set) var didExpire = false
  private(set) var expirationCount = 0
  @ObservationIgnored private var deadline: ContinuousClock.Instant?
  @ObservationIgnored private var expiry: Task<Void, Never>?
  @ObservationIgnored private var countdown: Task<Void, Never>?
  @ObservationIgnored private var onExpire: (@MainActor @Sendable () async -> Void)?
  private var generation = UUID()
  private var isForeground = true
  private var isClosed = false

  var isActive: Bool { deadline != nil }
  var remainingLabel: String? {
    guard let remainingSeconds else { return nil }
    return String(format: "%d:%02d", remainingSeconds / 60, remainingSeconds % 60)
  }

  func start(minutes: Int, onExpire: @escaping @MainActor @Sendable () async -> Void) {
    guard !isClosed, Self.presets.contains(minutes) else { return }
    cancel()
    didExpire = false
    activeMinutes = minutes
    remainingSeconds = minutes * 60
    let deadline = ContinuousClock.now.advanced(by: .seconds(minutes * 60))
    self.deadline = deadline
    self.onExpire = onExpire
    let request = generation
    expiry = Task { [weak self] in
      do { try await ContinuousClock().sleep(until: deadline) } catch { return }
      guard let self, request == self.generation, !self.isClosed else { return }
      await self.refreshElapsed()
    }
    resumeCountdown()
  }

  func cancel() {
    generation = UUID()
    expiry?.cancel()
    expiry = nil
    countdown?.cancel()
    countdown = nil
    deadline = nil
    onExpire = nil
    activeMinutes = nil
    remainingSeconds = nil
    didExpire = false
  }

  func refreshElapsed() async {
    guard !isClosed, let deadline else { return }
    let remaining = ContinuousClock.now.duration(to: deadline)
    if remaining <= .zero {
      let callback = onExpire
      generation = UUID()
      expiry = nil
      countdown = nil
      self.deadline = nil
      onExpire = nil
      activeMinutes = nil
      remainingSeconds = nil
      didExpire = true
      expirationCount += 1
      await callback?()
    } else {
      let parts = remaining.components
      remainingSeconds = Int(parts.seconds) + (parts.attoseconds > 0 ? 1 : 0)
    }
  }

  func foreground() async {
    guard !isClosed else { return }
    isForeground = true
    await refreshElapsed()
    resumeCountdown()
  }

  func background() {
    isForeground = false
    countdown?.cancel()
    countdown = nil
  }

  func close() {
    isClosed = true
    cancel()
  }

  private func resumeCountdown() {
    guard !isClosed, isForeground, isActive, countdown == nil else { return }
    let request = generation
    countdown = Task { [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(1)) } catch { return }
        guard let self, !self.isClosed, request == self.generation else { return }
        await self.refreshElapsed()
        guard request == self.generation else { return }
      }
    }
  }
}
