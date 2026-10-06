import Foundation

struct AudioByteChunk: Sendable {
  let data: Data
  let totalBytes: Int64
  let mimeType: String
}

enum AudioStreamFormat {
  static let mimeTypes = [
    "m4a": "audio/mp4", "m4b": "audio/mp4", "mp3": "audio/mpeg",
    "flac": "audio/flac", "ogg": "audio/ogg", "opus": "audio/ogg",
  ]
  static let chunkLimit = 256 * 1024
}
