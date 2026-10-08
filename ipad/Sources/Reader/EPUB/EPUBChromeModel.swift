import Foundation
import Observation

private struct EPUBChromePreferences: Codable {
  var controlsPinned = true
  var contentsPinned = false
}

@MainActor @Observable
final class EPUBChromeModel {
  private let api: BookOrbitAPI
  private let fileID: Int
  private var preferences = EPUBChromePreferences()
  private var key: String?
  private var generation: UUID?
  private var isClosed = false
  private(set) var controlsVisible = true
  private(set) var message: String?

  init(api: BookOrbitAPI, fileID: Int) {
    self.api = api
    self.fileID = fileID
  }

  var controlsPinned: Bool { preferences.controlsPinned }
  var contentsPinned: Bool { preferences.contentsPinned }

  func load() async {
    do {
      let session = try await api.authenticatedSessionGeneration()
      let namespace = try await api.storageNamespace()
      guard !isClosed, try await api.authenticatedSessionGeneration() == session else { return }
      generation = session
      key = "bookorbit.epub-chrome.\(namespace).file.\(fileID)"
      if let key, let data = UserDefaults.standard.data(forKey: key), data.count <= 1024,
        let saved = try? JSONDecoder().decode(EPUBChromePreferences.self, from: data)
      {
        preferences = saved
      }
    } catch {
      if !isClosed { message = "Reader display choices apply until this reader closes." }
    }
  }

  func showControls() { controlsVisible = true }
  func hideControls() { controlsVisible = false }

  func didNavigate() {
    if !controlsPinned { controlsVisible = false }
  }

  func toggleControlsPin() async {
    await togglePin(contents: false)
    if controlsPinned { showControls() }
  }

  func toggleContentsPin() async {
    await togglePin(contents: true)
  }

  func close() {
    isClosed = true
    key = nil
    generation = nil
  }

  private func togglePin(contents: Bool) async {
    guard !isClosed else { return }
    do {
      if let generation {
        guard try await api.authenticatedSessionGeneration() == generation else {
          throw ConnectionError.expiredSession
        }
      }
      guard !isClosed else { return }
      if contents {
        preferences.contentsPinned.toggle()
      } else {
        preferences.controlsPinned.toggle()
      }
      if let key {
        UserDefaults.standard.set(try JSONEncoder().encode(preferences), forKey: key)
      }
    } catch {
      if !isClosed {
        message = "The reading session changed. Close the reader before changing display choices."
        showControls()
      }
    }
  }
}
