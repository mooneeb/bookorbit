import Foundation
import Network

final class ReflowServer: @unchecked Sendable {
  private var listener: NWListener?
  private let root: URL
  private let rootNeededNormalization: Bool
  private var requests: [[String: Any]] = []
  var diagnosticURL: URL?

  init(root: URL = Bundle.main.resourceURL!) {
    self.root = root.resolvingSymlinksInPath().standardizedFileURL
    rootNeededNormalization = self.root.path != root.path
  }

  func start(ready: @escaping @Sendable (UInt16) -> Void) throws {
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    let listener = try NWListener(using: parameters)
    self.listener = listener
    listener.stateUpdateHandler = { [weak listener] state in
      if case .ready = state, let port = listener?.port { ready(port.rawValue) }
    }
    listener.newConnectionHandler = { [weak self] connection in
      guard let self else {
        connection.cancel()
        return
      }
      connection.start(queue: .main)
      connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
        guard let data,
          let request = String(data: data, encoding: .utf8),
          let target = request.components(separatedBy: "\r\n").first?.split(separator: " ")
            .dropFirst().first,
          let path = String(target).components(separatedBy: "?").first?.removingPercentEncoding
        else {
          connection.cancel()
          return
        }
        let url = self.root.appending(path: path).resolvingSymlinksInPath().standardizedFileURL
        let allowed = ["Fixtures/Reflow/", "foliate/"].contains {
          let directory = self.root.appending(path: $0).resolvingSymlinksInPath()
            .standardizedFileURL
          return url.path.hasPrefix(directory.path + "/")
        }
        let payload = allowed ? try? Data(contentsOf: url) : nil
        self.record(path: path, allowed: allowed, found: payload != nil)
        let types = [
          "html": "text/html", "js": "text/javascript", "css": "text/css",
          "epub": "application/epub+zip", "json": "application/json", "svg": "image/svg+xml",
        ]
        let body = payload ?? Data("Not found".utf8)
        let status = payload == nil ? "404 Not Found" : "200 OK"
        let header =
          "HTTP/1.1 \(status)\r\nContent-Type: \(types[url.pathExtension] ?? "application/octet-stream")\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        connection.send(
          content: Data(header.utf8) + body,
          completion: .contentProcessed { _ in connection.cancel() })
      }
    }
    listener.start(queue: .main)
  }

  private func record(path: String, allowed: Bool, found: Bool) {
    requests.append([
      "path": allowed ? path : "outside bundled resource directories",
      "allowed": allowed, "status": found ? 200 : 404,
      "bundleRootNeededNormalization": rootNeededNormalization,
    ])
    if requests.count > 40 { requests.removeFirst(requests.count - 40) }
    guard let diagnosticURL,
      let data = try? JSONSerialization.data(withJSONObject: requests, options: [.prettyPrinted])
    else { return }
    try? FileManager.default.createDirectory(
      at: diagnosticURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? data.write(to: diagnosticURL, options: .atomic)
  }

  func stop() {
    listener?.stateUpdateHandler = nil
    listener?.newConnectionHandler = nil
    listener?.cancel()
    listener = nil
  }
}
