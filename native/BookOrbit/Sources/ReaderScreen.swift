import SwiftUI
import WebKit

struct ReaderScreen: View {
    let publication: Publication
    let api: Transport
    @Environment(\.dismiss) private var dismiss
    @State private var model = ReaderModel()
    var body: some View {
        VStack {
            HStack {
                Button("Return to book details") { dismiss() }
                Spacer()
                Text(model.status).accessibilityAddTraits(.updatesFrequently)
            }.padding()
            if let web = model.web { ReaderWebView(web: web) }
            else { ProgressView("Opening EPUB") }
            if let error = model.error { Text(error).foregroundStyle(.red).padding() }
            HStack {
                Button("Previous page") { model.turn("prev") }
                Spacer()
                Button("Next page") { model.turn("next") }
            }.disabled(!model.ready).padding()
        }
        .task { await model.open(publication: publication, api: api) }
        .onDisappear { model.close(); Task { await api.close(publication) } }
    }
}
struct ReaderWebView: UIViewRepresentable {
    let web: WKWebView
    func makeUIView(context: Context) -> WKWebView { web }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

@MainActor @Observable
final class ReaderModel: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    var web: WKWebView?
    var ready = false
    var status = "Opening EPUB"
    var error: String?
    private var server: LoopbackServer?
    private var timeout: Task<Void, Never>?

    func open(publication: Publication, api: Transport) async {
        do {
            let server = LoopbackServer(publication: publication, api: api)
            self.server = server
            let url = try await server.start()
            guard !Task.isCancelled else { server.stop(); return }
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.userContentController.add(self, name: "reader")
            let rules = #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}},{"trigger":{"url-filter":"^blob:"},"action":{"type":"ignore-previous-rules"}},{"trigger":{"url-filter":"^data:"},"action":{"type":"ignore-previous-rules"}},{"trigger":{"url-filter":"^http://127\\.0\\.0\\.1:PORT/TOKEN/"},"action":{"type":"ignore-previous-rules"}}]"#
                .replacingOccurrences(of: "PORT", with: String(url.port!)).replacingOccurrences(of: "TOKEN", with: server.token)
            let ruleList = try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "BookOrbit-\(server.token)", encodedContentRuleList: rules)
            guard let ruleList else { throw ReaderFailure.message("Reader containment could not be enabled.") }
            configuration.userContentController.add(ruleList)
            let web = WKWebView(frame: .zero, configuration: configuration)
            web.navigationDelegate = self
            web.isInspectable = false
            self.web = web
            web.load(URLRequest(url: url))
            timeout = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled, self?.ready == false else { return }
                self?.fail("The chapter did not load within ten seconds. Return to details and retry.")
            }
        } catch { fail(error.localizedDescription) }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.webView === web, message.frameInfo.isMainFrame, let server, let url = server.url,
              message.frameInfo.securityOrigin.protocol == "http", message.frameInfo.securityOrigin.host == "127.0.0.1",
              message.frameInfo.securityOrigin.port == url.port,
              let body = message.body as? [String: String], body.count == 3, body["session"] == server.token,
              let value = body["value"], value.utf8.count <= 256 else { return }
        switch body["kind"] {
        case "ready": ready = true; status = "EPUB ready"; timeout?.cancel()
        case "location": status = value
        case "error": fail(value)
        default: break
        }
    }

    func turn(_ direction: String) {
        guard ready, direction == "next" || direction == "prev" else { return }
        web?.evaluateJavaScript("window.readerTurn('\(direction)')") { [weak self] _, error in
            if error != nil { self?.fail("Page navigation failed. Reopen the book.") }
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let destination = navigationAction.request.url else { return .cancel }
        if navigationAction.targetFrame?.isMainFrame == true {
            return destination == server?.url ? .allow : .cancel
        }
        return destination.scheme == "blob" || destination.absoluteString == "about:srcdoc" || destination.absoluteString == "about:blank" ? .allow : .cancel
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { fail("Reader stopped. Return to details and reopen the book.") }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail("Reader could not connect. Return to details and retry.") }

    private func fail(_ message: String) { ready = false; error = message; status = "Reading unavailable"; web?.stopLoading() }

    func close() {
        timeout?.cancel()
        web?.configuration.userContentController.removeScriptMessageHandler(forName: "reader")
        web?.stopLoading()
        web = nil
        if let token = server?.token { WKContentRuleListStore.default().removeContentRuleList(forIdentifier: "BookOrbit-\(token)") { _ in } }
        server?.stop()
        server = nil
    }
}
