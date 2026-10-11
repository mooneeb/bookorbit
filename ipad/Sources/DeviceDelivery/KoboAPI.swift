import Foundation

extension BookOrbitAPI {
  func koboSettings() async throws -> KoboSyncSettings {
    try await boundedJSON("kobo/settings", byteLimit: 16 * 1024)
  }

  func updateKoboSettings(_ settings: KoboSyncSettings) async throws -> KoboSyncSettings {
    try await boundedJSON(
      "kobo/settings", method: "PATCH", body: JSONEncoder().encode(settings),
      byteLimit: 16 * 1024)
  }

  func koboDevices() async throws -> [KoboDevice] {
    try await boundedJSON("kobo/devices", byteLimit: 128 * 1024)
  }

  func registerKoboDevice(name: String) async throws -> KoboDeviceWithToken {
    try await boundedJSON(
      "kobo/devices", method: "POST",
      body: JSONEncoder().encode(CreateKoboDeviceRequest(name: name)), byteLimit: 16 * 1024)
  }

  func renameKoboDevice(id: Int, name: String) async throws -> KoboDevice {
    try await boundedJSON(
      "kobo/devices/\(id)", method: "PATCH",
      body: JSONEncoder().encode(RenameKoboDeviceRequest(name: name)), byteLimit: 16 * 1024)
  }

  func revokeKoboDevice(id: Int) async throws {
    try await sendEmpty("kobo/devices/\(id)", method: "DELETE", expectedStatus: 204)
  }

  func koboHistory() async throws -> [KoboSyncHistoryEntry] {
    let entries: [KoboSyncHistoryEntry] = try await boundedJSON(
      "kobo/history", query: [.init(name: "limit", value: "40")], byteLimit: 256 * 1024)
    guard entries.count <= 40 else { throw ConnectionError.invalidResponse }
    return entries
  }

  func koboBookState(_ bookID: Int) async throws -> BookKoboState {
    try await boundedJSON("books/\(bookID)/kobo-state", byteLimit: 128 * 1024)
  }

  func koboCredentialURL(token: String) -> URL { profile.endpoint("kobo/\(token)") }
}
