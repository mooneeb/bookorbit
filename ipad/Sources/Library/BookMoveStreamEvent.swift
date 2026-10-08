import Foundation

enum BookMoveRejection: LocalizedError {
  case status(Int)

  var errorDescription: String? {
    switch self {
    case .status(403):
      "The server denied the move. Editor access and metadata editing permission are required."
    case .status(409):
      "The server could not start the move because a scan or another move is running. Wait, then prepare a fresh preview."
    case .status(404):
      "The selected book or destination is no longer available. Reload before preparing another move."
    case .status: "The server rejected the move request. Reload before preparing another move."
    }
  }
}

enum BookMoveStreamEvent: Decodable, Sendable {
  case book(BookMoveBookProgress)
  case completed(BookMoveCompletionEvent)

  private enum CodingKeys: String, CodingKey { case done }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if container.contains(.done) {
      guard try container.decode(Bool.self, forKey: .done) else {
        throw DecodingError.dataCorruptedError(
          forKey: .done, in: container, debugDescription: "Invalid move completion")
      }
      self = .completed(try BookMoveCompletionEvent(from: decoder))
    } else {
      self = .book(try BookMoveBookProgress(from: decoder))
    }
  }
}
