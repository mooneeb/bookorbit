import Foundation

struct AudioVolumeMemory {
  private(set) var previousVolume = 1.0

  mutating func remember(_ volume: Double) {
    if volume.isFinite, volume > 0, volume <= 1 { previousVolume = volume }
  }

  func toggledVolume(_ volume: Double) -> Double { volume > 0 ? 0 : previousVolume }
}
