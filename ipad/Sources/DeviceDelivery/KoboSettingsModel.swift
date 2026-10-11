import Foundation
import Observation

@MainActor @Observable
final class KoboSettingsModel {
  let api: BookOrbitAPI
  var settings: KoboSyncSettings?
  private(set) var devices: [KoboDevice] = []
  private(set) var isBusy = false
  var error: String?
  var notice: String?
  var credentialURL: URL?

  init(api: BookOrbitAPI) { self.api = api }

  func load() async {
    await perform {
      async let settings = self.api.koboSettings()
      async let devices = self.api.koboDevices()
      (self.settings, self.devices) = try await (settings, devices)
    }
  }

  func save() async {
    guard let settings else { return }
    await perform {
      self.settings = try await self.api.updateKoboSettings(settings)
      self.notice = "Kobo settings saved. Sync your Kobo to apply them."
    }
  }

  func register(name: String) async {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name.count <= 255 else {
      error = "Enter a device name with at most 255 characters."
      return
    }
    await perform {
      let device = try await self.api.registerKoboDevice(name: name)
      self.credentialURL = await self.api.koboCredentialURL(token: device.token)
      self.devices = try await self.api.koboDevices()
    }
  }

  func rename(_ device: KoboDevice, name: String) async {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name.count <= 255 else {
      error = "Enter a device name with at most 255 characters."
      return
    }
    await perform {
      let updated = try await self.api.renameKoboDevice(id: device.id, name: name)
      self.devices = self.devices.map { $0.id == updated.id ? updated : $0 }
      self.notice = "Device name saved."
    }
  }

  func revoke(_ device: KoboDevice) async {
    await perform {
      try await self.api.revokeKoboDevice(id: device.id)
      self.devices.removeAll { $0.id == device.id }
      self.notice = "Device credential revoked."
    }
  }

  private func perform(_ operation: () async throws -> Void) async {
    guard !isBusy else { return }
    isBusy = true
    error = nil
    notice = nil
    defer { isBusy = false }
    do { try await operation() } catch { self.error = error.localizedDescription }
  }
}
