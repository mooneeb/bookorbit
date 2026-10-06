import AVFoundation
import Foundation
import UniformTypeIdentifiers

struct AudioAssetDescriptor: Sendable {
  let bookID: Int
  let assetID: String
  let format: String
  let sizeBytes: Int64?
}

enum AudioProofError: LocalizedError {
  case unsupported
  case tooManyRequests
  case invalidManifest

  var errorDescription: String? {
    switch self {
    case .unsupported: "This audio format is not supported by the native playback engine."
    case .tooManyRequests: "The playback engine requested too many concurrent audio ranges."
    case .invalidManifest: "The server returned an incompatible audiobook manifest."
    }
  }
}

@MainActor
final class AudioResourceLoader: NSObject, AVAssetResourceLoaderDelegate {
  let url: URL
  let descriptor: AudioAssetDescriptor
  private let api: BookOrbitAPI
  private let sessionGeneration: UUID
  private var requests: [ObjectIdentifier: AVAssetResourceLoadingRequest] = [:]
  private var pending: [ObjectIdentifier] = []
  private var active: [ObjectIdentifier: Task<Void, Never>] = [:]
  private var totalBytes: Int64?
  private var isClosed = false
  private(set) var requestCount = 0
  private(set) var deliveredBytes: Int64 = 0
  private(set) var peakActive = 0
  private(set) var peakRequests = 0

  init(api: BookOrbitAPI, descriptor: AudioAssetDescriptor, sessionGeneration: UUID) {
    self.api = api
    self.descriptor = descriptor
    self.sessionGeneration = sessionGeneration
    url = URL(string: "bookorbit-audio://\(UUID().uuidString)/asset.\(descriptor.format)")!
    super.init()
  }

  nonisolated func resourceLoader(
    _ resourceLoader: AVAssetResourceLoader,
    shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
  ) -> Bool {
    MainActor.assumeIsolated { accept(loadingRequest) }
  }

  nonisolated func resourceLoader(
    _ resourceLoader: AVAssetResourceLoader,
    didCancel loadingRequest: AVAssetResourceLoadingRequest
  ) {
    MainActor.assumeIsolated {
      let id = ObjectIdentifier(loadingRequest)
      requests.removeValue(forKey: id)
      pending.removeAll { $0 == id }
      active[id]?.cancel()
      pump()
    }
  }

  func close() {
    isClosed = true
    for task in active.values { task.cancel() }
    for request in requests.values where !request.isCancelled && !request.isFinished {
      request.finishLoading(with: CancellationError())
    }
    requests.removeAll()
    pending.removeAll()
  }

  private func accept(_ request: AVAssetResourceLoadingRequest) -> Bool {
    guard request.request.url == url else { return false }
    guard !isClosed else {
      request.finishLoading(with: CancellationError())
      return true
    }
    guard requests.count < 8 else {
      request.finishLoading(with: AudioProofError.tooManyRequests)
      return true
    }
    let id = ObjectIdentifier(request)
    requests[id] = request
    pending.append(id)
    peakRequests = max(peakRequests, requests.count)
    pump()
    return true
  }

  private func pump() {
    guard !isClosed else { return }
    while active.count < 2, !pending.isEmpty {
      let id = pending.removeFirst()
      guard requests[id] != nil, active[id] == nil else { continue }
      active[id] = Task { [weak self] in
        guard let self else { return }
        defer {
          self.active.removeValue(forKey: id)
          self.pump()
        }
        do {
          let finished = try await self.provideChunk(id)
          if finished {
            self.finish(id)
          } else if self.requests[id] != nil {
            self.pending.append(id)
          }
        } catch {
          self.finish(id, error: error)
        }
      }
      peakActive = max(peakActive, active.count)
    }
  }

  private func provideChunk(_ id: ObjectIdentifier) async throws -> Bool {
    if totalBytes == nil {
      let discovery = try await chunk(offset: 0, length: 1)
      try Task.checkCancellation()
      guard requests[id] != nil, !isClosed else { throw CancellationError() }
      totalBytes = discovery.totalBytes
    }
    guard let totalBytes, let request = requests[id], !request.isCancelled else {
      throw CancellationError()
    }
    if let info = request.contentInformationRequest {
      guard let mime = AudioStreamFormat.mimeTypes[descriptor.format],
        let contentType = UTType(mimeType: mime)?.identifier,
        info.allowedContentTypes?.isEmpty != false
          || info.allowedContentTypes?.contains(contentType) == true
      else { throw AudioProofError.unsupported }
      info.contentType = contentType
      info.contentLength = totalBytes
      info.isByteRangeAccessSupported = true
      info.isEntireLengthAvailableOnDemand = false
    }
    guard let data = request.dataRequest else { return true }
    let offset = max(data.currentOffset, data.requestedOffset)
    let (requestedEnd, overflow) = data.requestedOffset.addingReportingOverflow(
      Int64(data.requestedLength))
    guard data.requestedOffset >= 0, data.requestedLength >= 0,
      data.requestsAllDataToEndOfResource || !overflow, offset >= 0, offset <= totalBytes
    else { throw ConnectionError.invalidResponse }
    let end = data.requestsAllDataToEndOfResource ? totalBytes : min(totalBytes, requestedEnd)
    guard offset < end else { return true }
    let length = Int(min(Int64(AudioStreamFormat.chunkLimit), end - offset))
    let delivery = try await chunk(offset: offset, length: length)
    try Task.checkCancellation()
    guard let live = requests[id], !live.isCancelled, !isClosed else {
      throw CancellationError()
    }
    guard live.dataRequest?.currentOffset == offset else { throw ConnectionError.invalidResponse }
    live.dataRequest?.respond(with: delivery.data)
    return offset + Int64(delivery.data.count) >= end
  }

  private func chunk(offset: Int64, length: Int) async throws -> AudioByteChunk {
    requestCount += 1
    let result = try await api.audioChunk(
      bookID: descriptor.bookID, assetID: descriptor.assetID, format: descriptor.format,
      offset: offset, length: length, expectedSize: totalBytes ?? descriptor.sizeBytes,
      generation: sessionGeneration)
    deliveredBytes += Int64(result.data.count)
    return result
  }

  private func finish(_ id: ObjectIdentifier, error: (any Error)? = nil) {
    guard let request = requests.removeValue(forKey: id), !request.isCancelled,
      !request.isFinished
    else { return }
    if let error {
      request.finishLoading(with: error)
    } else {
      request.finishLoading()
    }
  }
}
