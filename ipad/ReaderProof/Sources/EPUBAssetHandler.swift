import Foundation
import WebKit

@MainActor
final class EPUBAssetHandler: NSObject, WKURLSchemeHandler {
  let origin = URL(string: "bookorbit-reader://\(UUID().uuidString.lowercased())")!
  var root: URL?

  func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
    guard let root, let url = urlSchemeTask.request.url,
      url.scheme == origin.scheme, url.host == origin.host, url.query == nil,
      !url.path.contains("\\"), !url.path.split(separator: "/").contains("..")
    else {
      urlSchemeTask.didFailWithError(URLError(.resourceUnavailable))
      return
    }
    let asset = root.appendingPathComponent(String(url.path.dropFirst())).standardizedFileURL
    let types = ["html": "text/html", "js": "text/javascript", "css": "text/css"]
    guard asset.path.hasPrefix(root.path + "/"), let type = types[asset.pathExtension] else {
      urlSchemeTask.didFailWithError(URLError(.resourceUnavailable))
      return
    }
    do {
      let data = try Data(contentsOf: asset)
      guard
        let response = HTTPURLResponse(
          url: url, statusCode: 200, httpVersion: "HTTP/1.1",
          headerFields: [
            "Content-Type": "\(type); charset=utf-8",
            "Access-Control-Allow-Origin": "*",
          ])
      else { throw URLError(.badServerResponse) }
      urlSchemeTask.didReceive(response)
      urlSchemeTask.didReceive(data)
      urlSchemeTask.didFinish()
    } catch {
      urlSchemeTask.didFailWithError(error)
    }
  }

  func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}
