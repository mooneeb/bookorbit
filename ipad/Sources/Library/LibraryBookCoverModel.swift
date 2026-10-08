import Foundation
import Observation
import UIKit

struct LibraryBookCoverRequest: Hashable {
  let apiID: ObjectIdentifier
  let bookID: Int
  let version: String
  let hasCover: Bool
}

enum LibraryBookCoverState {
  case absent
  case loading
  case loaded(UIImage)
  case failed
}

@MainActor @Observable
final class LibraryBookCoverModel {
  private var request: LibraryBookCoverRequest?
  private var currentState = LibraryBookCoverState.absent
  private var operation = UUID()

  func state(for request: LibraryBookCoverRequest) -> LibraryBookCoverState {
    guard self.request == request else { return request.hasCover ? .loading : .absent }
    return currentState
  }

  func load(api: BookOrbitAPI, request: LibraryBookCoverRequest) async {
    let id = UUID()
    operation = id
    self.request = request
    currentState = request.hasCover ? .loading : .absent
    guard request.hasCover else { return }
    do {
      let namespace = try await api.imageNamespace()
      try Task.checkCancellation()
      guard operation == id else { return }
      let image = try await CoverPreviewLoader.shared.thumbnail(
        api: api, bookID: request.bookID, version: request.version, namespace: namespace)
      try Task.checkCancellation()
      guard operation == id else { return }
      currentState = .loaded(image)
    } catch {
      guard operation == id, !Task.isCancelled else { return }
      currentState = .failed
    }
  }

  func cancel() {
    operation = UUID()
    request = nil
    currentState = .absent
  }
}
