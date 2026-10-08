import Foundation

extension ClearFileProgressQuery {
  var urlQuery: [URLQueryItem] {
    [
      URLQueryItem(name: "textVersion", value: textVersion),
      URLQueryItem(name: "narrationVersion", value: narrationVersion),
    ]
  }
}

extension ClearTtsPositionQuery {
  var urlQuery: [URLQueryItem] { [URLQueryItem(name: "baseVersion", value: baseVersion)] }
}

extension DeleteAudiobookPlaybackStateQuery {
  var urlQuery: [URLQueryItem] {
    [
      URLQueryItem(name: "baseRevision", value: baseRevision.map { String($0) }),
      URLQueryItem(name: "manifestRevision", value: manifestRevision),
    ]
  }
}
