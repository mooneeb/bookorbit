import SwiftUI
import WebKit

struct EPUBProofView: View {
  @State private var model: EPUBProofModel
  @Environment(\.dismiss) private var dismiss
  @FocusState private var editsAnchor: Bool

  init(api: BookOrbitAPI, bookID: Int, file: BookDetailFile) {
    _model = State(initialValue: EPUBProofModel(api: api, bookID: bookID, file: file))
  }

  var body: some View {
    NavigationStack {
      VStack {
        EPUBContentView(webView: model.webView)
        if !model.isReady, model.error == nil { ProgressView("Opening EPUB…") }
        if let error = model.error { Text(error).foregroundStyle(.primary) }
        VStack {
          if model.isPlainChapter {
            Text("Plain chapter loaded")
          } else {
            TextField("Passage anchor", text: $model.anchor)
              .frame(minHeight: 44)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
              .accessibilityIdentifier("passageAnchor")
              .focused($editsAnchor)
              .disabled(model.isSaving)
            Button("Resolve passage", action: resolvePassage)
              .frame(maxWidth: .infinity, minHeight: 44)
              .contentShape(Rectangle())
              .disabled(!model.isReady || model.isResolving || model.isSaving)
            if model.isResolving { ProgressView("Resolving passage…") }
            if !model.resolvedText.isEmpty {
              Text(model.resolvedText).accessibilityIdentifier("resolvedPassage")
              Text(model.roundTripAnchor).accessibilityIdentifier("roundTripAnchor")
              Button("Save passage position", action: model.savePassagePosition)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
                .disabled(model.isSaving || model.isResolving)
            }
            if !model.status.isEmpty { Text(model.status) }
            Button("Inspect plain chapter", action: inspectPlainChapter)
              .frame(maxWidth: .infinity, minHeight: 44)
              .contentShape(Rectangle())
              .disabled(!model.isReady || model.isResolving || model.isSaving)
          }
          Button("Close reader", action: dismiss.callAsFunction)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
            .disabled(model.isSaving)
        }
        .buttonStyle(.plain)
        .font(.body)
        .foregroundStyle(.primary)
        .padding()
      }
      .navigationTitle("EPUB renderer proof")
      .navigationBarTitleDisplayMode(.inline)
    }
    .task { await model.load() }
    .onDisappear { model.close() }
  }

  private func resolvePassage() {
    editsAnchor = false
    model.resolvePassage()
  }

  private func inspectPlainChapter() {
    editsAnchor = false
    model.inspectPlainChapter()
  }
}

private struct EPUBContentView: UIViewRepresentable {
  let webView: WKWebView
  func makeUIView(context: Context) -> WKWebView { webView }
  func updateUIView(_ uiView: WKWebView, context: Context) {}
}
