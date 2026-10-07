import Foundation
import WebKit

@MainActor
final class EPUBPublicationResources: NSObject, WKURLSchemeHandler, WKScriptMessageHandlerWithReply
{
  let origin = URL(string: "bookorbit-publication://\(UUID().uuidString.lowercased())")!
  private let api: BookOrbitAPI
  private let bookID: Int
  private let fileID: Int
  private var generation: UUID?
  private var root: URL?
  private(set) var entry: URL?
  private var paths: Set<String> = []
  private var sizes: [String: Int] = [:]
  private var deliveredFile: URL?
  private var deliveredSize = 0
  private var tasks: [UUID: Task<Void, Never>] = [:]
  private var isClosed = false

  init(api: BookOrbitAPI, bookID: Int, fileID: Int) {
    self.api = api
    self.bookID = bookID
    self.fileID = fileID
  }

  func prepare(_ info: EpubBookInfo, session: UUID) throws -> URL {
    guard root == nil, !isClosed, info.spine.count <= 4096,
      !info.spine.isEmpty, info.manifest.count <= 65_536,
      info.manifest.allSatisfy({ Self.validPath($0.href) && $0.size >= 0 }),
      Self.validPath(info.containerPath),
      Set(info.manifest.map(\.id)).count == info.manifest.count,
      Set(info.manifest.map(\.href)).count == info.manifest.count,
      (info.optionalFiles ?? []).allSatisfy(Self.validPath)
    else { throw ConnectionError.invalidResponse }
    let manifest = Dictionary(uniqueKeysWithValues: info.manifest.map { ($0.id, $0) })
    guard
      info.spine.allSatisfy({ item in
        manifest[item.idref]?.href == item.href && manifest[item.idref]?.mediaType == item.mediaType
      })
    else { throw ConnectionError.invalidResponse }
    generation = session
    sizes = Dictionary(uniqueKeysWithValues: info.manifest.map { ($0.href, $0.size) })
    paths = Set(
      info.manifest.map(\.href) + (info.optionalFiles ?? []) + [
        "META-INF/container.xml", info.containerPath,
      ])
    return try prepareAssets()
  }

  func prepareDelivered(_ file: URL, size: Int, session: UUID) throws -> URL {
    guard root == nil, !isClosed, (1...(64 * 1024 * 1024)).contains(size) else {
      throw ConnectionError.invalidResponse
    }
    deliveredFile = file
    deliveredSize = size
    generation = session
    let entry = try prepareAssets()
    guard let root else { throw ConnectionError.invalidResponse }
    let destination = root.appendingPathComponent("publication.content")
    try FileManager.default.moveItem(at: file, to: destination)
    deliveredFile = destination
    return entry
  }

  private func prepareAssets() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
      "bookorbit-publication-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    root = folder
    for name in ["EPUBReader", "foliate"] {
      guard let source = Bundle.main.url(forResource: name, withExtension: nil) else {
        throw ConnectionError.invalidResponse
      }
      try FileManager.default.copyItem(at: source, to: folder.appendingPathComponent(name))
    }
    let url = origin.appendingPathComponent("EPUBReader/index.html")
    entry = url
    return url
  }

  func userContentController(
    _ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
    replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
  ) {
    guard !isClosed, message.frameInfo.isMainFrame, message.frameInfo.request.url == entry,
      tasks.count < 2, let generation
    else {
      replyHandler(nil, "The publication resource is unavailable.")
      return
    }
    if let range = message.body as? [String: Any] {
      guard let file = deliveredFile, let offset = range["offset"] as? Int,
        let length = range["length"] as? Int, range.count == 2,
        offset >= 0, (1...(1024 * 1024)).contains(length),
        offset <= deliveredSize - length
      else {
        replyHandler(nil, "The delivered ebook range is unavailable.")
        return
      }
      let id = UUID()
      tasks[id] = Task {
        defer { tasks[id] = nil }
        do {
          guard try await api.authenticatedSessionGeneration() == generation else {
            throw ConnectionError.expiredSession
          }
          let handle = try FileHandle(forReadingFrom: file)
          defer { try? handle.close() }
          try handle.seek(toOffset: UInt64(offset))
          let data = try handle.read(upToCount: length) ?? Data()
          try Task.checkCancellation()
          guard !isClosed, data.count == length,
            try await api.authenticatedSessionGeneration() == generation
          else { throw ConnectionError.fileChanged }
          replyHandler(data.base64EncodedString(), nil)
        } catch { replyHandler(nil, error.localizedDescription) }
      }
      return
    }
    guard let path = message.body as? String, paths.contains(path), Self.validPath(path) else {
      replyHandler(nil, "The publication resource is unavailable.")
      return
    }
    let id = UUID()
    tasks[id] = Task {
      defer { tasks[id] = nil }
      do {
        let data = try await api.epubResource(
          bookID: bookID, fileID: fileID, path: path, expectedSize: sizes[path],
          byteLimit: 8 * 1024 * 1024, session: generation)
        try Task.checkCancellation()
        guard !isClosed else { throw CancellationError() }
        replyHandler(data.base64EncodedString(), nil)
      } catch { replyHandler(nil, error.localizedDescription) }
    }
  }

  func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
    guard !isClosed, let root, let url = urlSchemeTask.request.url,
      url.scheme == origin.scheme, url.host == origin.host, url.query == nil,
      Self.validPath(String(url.path.dropFirst()))
    else {
      urlSchemeTask.didFailWithError(URLError(.resourceUnavailable))
      return
    }
    let asset = root.appendingPathComponent(String(url.path.dropFirst())).resolvingSymlinksInPath()
    let types = ["html": "text/html", "js": "text/javascript", "css": "text/css"]
    guard asset.path.hasPrefix(root.resolvingSymlinksInPath().path + "/"),
      let type = types[asset.pathExtension]
    else {
      urlSchemeTask.didFailWithError(URLError(.resourceUnavailable))
      return
    }
    do {
      let data = try Data(contentsOf: asset)
      guard data.count <= 2 * 1024 * 1024,
        let response = HTTPURLResponse(
          url: url, statusCode: 200, httpVersion: "HTTP/1.1",
          headerFields: [
            "Content-Type": "\(type); charset=utf-8", "Access-Control-Allow-Origin": "*",
          ])
      else { throw ConnectionError.invalidResponse }
      urlSchemeTask.didReceive(response)
      urlSchemeTask.didReceive(data)
      urlSchemeTask.didFinish()
    } catch { urlSchemeTask.didFailWithError(error) }
  }

  func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}

  func reset() {
    for task in tasks.values { task.cancel() }
    tasks.removeAll()
    if let deliveredFile { try? FileManager.default.removeItem(at: deliveredFile) }
    deliveredFile = nil
    deliveredSize = 0
    if let root { try? FileManager.default.removeItem(at: root) }
    root = nil
    entry = nil
    paths = []
    sizes = [:]
  }

  func close() {
    isClosed = true
    reset()
  }

  nonisolated static func validPath(_ path: String) -> Bool {
    !path.isEmpty && path.utf16.count <= 4096 && !path.hasPrefix("/")
      && !path.contains("\\") && !path.contains(":") && !path.contains("?") && !path.contains("#")
      && !path.contains("\u{0}") && !path.split(separator: "/").contains("..")
  }
}
