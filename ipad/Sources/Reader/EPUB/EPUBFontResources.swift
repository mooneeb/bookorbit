import Foundation
import WebKit

struct EPUBFontFace: Encodable {
  let family: String
  let url: String
  let format: String
  let weight: String
  let styles: [String]
}

@MainActor
final class EPUBFontResources: NSObject, WKURLSchemeHandler {
  private struct Source {
    let scope: String
    let font: UserFont
    var key: String { "\(scope):\(font.id)" }
  }
  private struct Request {
    let task: any WKURLSchemeTask
    let source: Source
  }
  private let api: BookOrbitAPI
  private let origin = URL(string: "bookorbit-font://\(UUID().uuidString.lowercased())")!
  private static let cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
    "bookorbit-reader-fonts", isDirectory: true)
  private static var removedAbandonedCache = false
  private static var cacheStartupFailure = false
  private let directory = EPUBFontResources.cacheRoot.appendingPathComponent(
    UUID().uuidString, isDirectory: true)
  private var storageFailure = false
  private var generation: UUID?
  private var sources: [URL: Source] = [:]
  private var requests: [UUID: Request] = [:]
  private var queue: [UUID] = []
  private var tasks: [UUID: Task<Void, Never>] = [:]
  private var cache: [String: ReaderFontFile] = [:]
  private var cacheOrder: [String] = []
  private var isClosed = false
  private(set) var failure: String?
  static let cacheEntryMaximum = 4
  static let cacheByteMaximum = 4 * ReaderFontVocabulary.fileMaximum

  init(api: BookOrbitAPI) {
    self.api = api
    super.init()
    if !Self.removedAbandonedCache {
      if FileManager.default.fileExists(atPath: Self.cacheRoot.path) {
        do { try FileManager.default.removeItem(at: Self.cacheRoot) } catch {
          Self.cacheStartupFailure = true
        }
      }
      Self.removedAbandonedCache = true
    }
    storageFailure = Self.cacheStartupFailure
  }

  func prepare(_ family: EPUBFontFamily?, weight: Double, style: String, session: UUID) throws
    -> [EPUBFontFace]
  {
    cancelRequests()
    sources = [:]
    generation = session
    failure = nil
    guard !isClosed else { throw ConnectionError.expiredSession }
    guard let family else { return [] }
    guard !storageFailure else { throw ConnectionError.insufficientStorage }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let files = try family.renderingFiles(weight: weight, style: style)
    return files.map { font in
      let url = origin.appendingPathComponent(UUID().uuidString.lowercased())
      sources[url] = Source(scope: family.scope, font: font)
      let variable = font.weightMin != nil && font.weightMax != nil
      let styles = Set([font.style] + (variable ? (font.instances ?? []).map(\.style) : []))
        .sorted()
      return EPUBFontFace(
        family: family.cssFamily, url: url.absoluteString,
        format: ReaderFontVocabulary.cssFormats[font.format] ?? "",
        weight: variable
          ? "\(Int(font.weightMin!)) \(Int(font.weightMax!))" : "\(Int(font.weight))",
        styles: styles)
    }
  }

  func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
    guard !isClosed, generation != nil,
      let url = urlSchemeTask.request.url, let source = sources[url],
      url.query == nil, url.fragment == nil,
      urlSchemeTask.request.httpMethod == "GET", requests.count < 10
    else {
      urlSchemeTask.didFailWithError(URLError(.resourceUnavailable))
      return
    }
    let id = UUID()
    requests[id] = Request(task: urlSchemeTask, source: source)
    queue.append(id)
    drain()
  }

  func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
    guard let id = requests.first(where: { $0.value.task === urlSchemeTask })?.key else { return }
    requests[id] = nil
    queue.removeAll { $0 == id }
    tasks[id]?.cancel()
  }

  private func drain() {
    while !isClosed, tasks.count < 2, !queue.isEmpty {
      let activeKeys = Set(tasks.keys.compactMap { requests[$0]?.source.key })
      guard
        let next = queue.firstIndex(where: { id in
          requests[id].map { !activeKeys.contains($0.source.key) } ?? true
        })
      else { break }
      let id = queue.remove(at: next)
      guard let request = requests[id], let generation else { continue }
      tasks[id] = Task { [weak self] in
        guard let self else { return }
        defer {
          self.tasks[id] = nil
          self.requests[id] = nil
          self.drain()
        }
        var received: ReaderFontFile?
        do {
          let key = request.source.key
          let file = try await self.api.readerFontFile(
            scope: request.source.scope, font: request.source.font, cached: self.cache[key],
            directory: self.directory,
            session: generation)
          received = file
          try Task.checkCancellation()
          guard !self.isClosed, self.requests[id] != nil,
            try await self.api.authenticatedSessionGeneration() == generation
          else { throw CancellationError() }
          self.store(file, key: key)
          received = nil
          let handle = try FileHandle(forReadingFrom: file.url)
          defer { try? handle.close() }
          guard let url = request.task.request.url,
            let response = HTTPURLResponse(
              url: url, statusCode: 200, httpVersion: "HTTP/1.1",
              headerFields: [
                "Content-Type": file.mimeType, "Content-Length": String(file.size),
                "Cache-Control": "no-store", "Access-Control-Allow-Origin": "*",
              ])
          else { throw EPUBFontError.invalidFile }
          request.task.didReceive(response)
          var sent = 0
          while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            guard !self.isClosed, self.requests[id] != nil,
              try await self.api.authenticatedSessionGeneration() == generation
            else { throw CancellationError() }
            sent += chunk.count
            guard sent <= file.size else { throw EPUBFontError.invalidFile }
            request.task.didReceive(chunk)
            await Task.yield()
          }
          guard sent == file.size else { throw EPUBFontError.invalidFile }
          try Task.checkCancellation()
          guard self.requests[id] != nil else { return }
          request.task.didFinish()
        } catch {
          if let received, !self.cache.values.contains(where: { $0.url == received.url }) {
            try? FileManager.default.removeItem(at: received.url)
          }
          if !self.isClosed, self.requests[id] != nil {
            self.failure = "The custom font could not be delivered. \(error.localizedDescription)"
            request.task.didFailWithError(error)
          }
        }
      }
    }
  }

  private func store(_ file: ReaderFontFile, key: String) {
    if let previous = cache[key], previous.url != file.url {
      try? FileManager.default.removeItem(at: previous.url)
    }
    cache[key] = file
    cacheOrder.removeAll { $0 == key }
    cacheOrder.append(key)
    while cache.count > Self.cacheEntryMaximum
      || cache.values.reduce(0, { $0 + $1.size }) > Self.cacheByteMaximum
    {
      guard let oldest = cacheOrder.first else { break }
      cacheOrder.removeFirst()
      if let evicted = cache.removeValue(forKey: oldest) {
        try? FileManager.default.removeItem(at: evicted.url)
      }
    }
  }

  private func cancelRequests() {
    for task in tasks.values { task.cancel() }
    for request in requests.values { request.task.didFailWithError(URLError(.cancelled)) }
    requests = [:]
    queue = []
  }

  func reset() {
    cancelRequests()
    sources = [:]
    generation = nil
    for file in cache.values { try? FileManager.default.removeItem(at: file.url) }
    try? FileManager.default.removeItem(at: directory)
    cache = [:]
    cacheOrder = []
    failure = nil
  }

  func close() {
    isClosed = true
    reset()
  }
}
