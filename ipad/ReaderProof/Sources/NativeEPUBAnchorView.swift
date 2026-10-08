import SwiftUI
import UIKit

struct NativeEPUBAnchorView: View {
  @State private var model: NativeEPUBAnchorModel
  @State private var showLocations = false
  @State private var fontSize: Double = 20
  @Environment(\.dismiss) private var dismiss

  init(api: BookOrbitAPI, bookID: Int, file: BookDetailFile) {
    _model = State(initialValue: NativeEPUBAnchorModel(api: api, bookID: bookID, file: file))
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        if let document = model.document {
          NativeEPUBAnchorTextView(
            document: document, fontSize: fontSize, selection: model.selection,
            revision: model.selectionRevision, onSelection: model.selectionChanged
          )
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.isLoading {
          ProgressView("Opening publication…")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          Text(model.error ?? "The publication could not be opened.")
            .padding().frame(maxWidth: .infinity, maxHeight: .infinity)
          Button("Retry opening") { Task { await model.load() } }
            .accessibilityIdentifier("nativeAnchorRetry")
        }
        if model.document != nil, let error = model.error {
          Text(error).padding().accessibilityIdentifier("nativeAnchorContentError")
        }
        Text(model.status)
          .padding().accessibilityIdentifier("nativeAnchorStatus")
      }
      .font(.body).foregroundStyle(.primary).background(.background)
      .navigationTitle("Native EPUB anchors")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("Close", action: dismiss.callAsFunction)
            .disabled(model.isBusy).accessibilityIdentifier("nativeAnchorClose")
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button("Locations") { showLocations = true }
            .disabled(model.document == nil).accessibilityIdentifier("nativeAnchorLocations")
        }
      }
      .sheet(isPresented: $showLocations) { locations }
    }
    .task { await model.load() }
    .onDisappear { model.close() }
  }

  private var locations: some View {
    NavigationStack {
      Form {
        Section("Saved location") {
          TextField("EPUB CFI", text: $model.anchorDraft, axis: .vertical)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .accessibilityIdentifier("nativeAnchorCFI")
          Button("Resolve location", action: model.resolveAnchor)
            .disabled(model.isBusy).accessibilityIdentifier("nativeAnchorResolve")
          Stepper("Text size: \(Int(fontSize))", value: $fontSize, in: 16...36, step: 2)
            .accessibilityIdentifier("nativeAnchorTextSize")
        }
        Section("Selection") {
          Text(model.selectionText.isEmpty ? "No passage selected" : model.selectionText)
            .accessibilityIdentifier("nativeAnchorSelectionText")
          Text(model.selectionCFI.isEmpty ? "No location selected" : model.selectionCFI)
            .textSelection(.enabled).accessibilityIdentifier("nativeAnchorSelectionCFI")
          Button("Save highlight", action: model.saveHighlight)
            .disabled(!model.canSaveHighlight).accessibilityIdentifier("nativeAnchorSaveHighlight")
          if model.uncertainHighlight {
            Button("Check saved highlights", action: model.checkHighlight)
              .disabled(model.isBusy).accessibilityIdentifier("nativeAnchorCheckHighlight")
          }
          Button("Save position", action: model.savePosition)
            .disabled(!model.canSavePosition).accessibilityIdentifier("nativeAnchorSavePosition")
        }
        Section("Latest 20 highlights") {
          ForEach(model.highlights) { highlight in
            Button(highlight.text) { model.openHighlight(highlight) }
              .disabled(model.isBusy || highlight.cfi == nil)
              .accessibilityIdentifier("nativeAnchorHighlight\(highlight.id)")
          }
        }
        Section {
          Text(model.status).accessibilityIdentifier("nativeAnchorSheetStatus")
          if let error = model.error {
            Text(error).accessibilityIdentifier("nativeAnchorError")
          }
          if model.isBusy { ProgressView("Saving…") }
        }
      }
      .navigationTitle("Passage locations")
      .toolbar {
        Button("Done") { showLocations = false }
          .disabled(model.isBusy).accessibilityIdentifier("nativeAnchorLocationsDone")
      }
    }
    .interactiveDismissDisabled(model.isBusy)
  }
}

private struct NativeEPUBAnchorTextView: UIViewRepresentable {
  let document: NativeEPUBTextDocument
  let fontSize: Double
  let selection: NSRange?
  let revision: Int
  let onSelection: @MainActor ([NSRange]) -> Void

  func makeCoordinator() -> Coordinator { Coordinator(onSelection: onSelection) }

  func makeUIView(context: Context) -> UITextView {
    let view = UITextView(usingTextLayoutManager: true)
    view.isEditable = false
    view.isSelectable = true
    view.backgroundColor = .systemBackground
    view.textColor = .label
    view.adjustsFontForContentSizeCategory = true
    view.textContainerInset = UIEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
    view.textContainer.lineFragmentPadding = 0
    view.accessibilityIdentifier = "nativeAnchorChapter"
    view.delegate = context.coordinator
    return view
  }

  func updateUIView(_ view: UITextView, context: Context) {
    let coordinator = context.coordinator
    coordinator.onSelection = onSelection
    coordinator.updating = true
    defer { coordinator.updating = false }
    view.accessibilityLanguage = document.language
    if coordinator.fontSize != fontSize
      || coordinator.contentSizeCategory != view.traitCollection.preferredContentSizeCategory
      || !view.text.utf16.elementsEqual(document.text.utf16)
    {
      let ranges = view.selectedRanges
      let descriptor = UIFont.systemFont(ofSize: fontSize).fontDescriptor
      let base = UIFont(descriptor: descriptor.withDesign(.serif) ?? descriptor, size: fontSize)
      let paragraph = NSMutableParagraphStyle()
      paragraph.lineHeightMultiple = 1.5
      let text = NSMutableAttributedString(
        string: document.text,
        attributes: [
          .font: UIFontMetrics(forTextStyle: .body).scaledFont(for: base),
          .foregroundColor: UIColor.label, .paragraphStyle: paragraph,
        ])
      for segment in document.segments {
        var traits: UIFontDescriptor.SymbolicTraits = []
        if segment.bold { traits.insert(.traitBold) }
        if segment.italic { traits.insert(.traitItalic) }
        let descriptor = base.fontDescriptor.withSymbolicTraits(traits) ?? base.fontDescriptor
        let font = UIFontMetrics(forTextStyle: .body).scaledFont(
          for: UIFont(descriptor: descriptor, size: fontSize))
        text.addAttribute(.font, value: font, range: segment.range)
      }
      view.attributedText = text
      view.selectedRanges = ranges
      coordinator.fontSize = fontSize
      coordinator.contentSizeCategory = view.traitCollection.preferredContentSizeCategory
    }
    if coordinator.revision != revision {
      coordinator.revision = revision
      if let selection {
        view.selectedRanges = [selection]
        view.scrollRangeToVisible(selection)
      } else {
        view.selectedRanges = []
      }
    }
  }

  @MainActor final class Coordinator: NSObject, UITextViewDelegate {
    var onSelection: @MainActor ([NSRange]) -> Void
    var updating = false
    var fontSize: Double?
    var contentSizeCategory: UIContentSizeCategory?
    var revision = -1

    init(onSelection: @escaping @MainActor ([NSRange]) -> Void) { self.onSelection = onSelection }

    func textViewDidChangeSelection(_ textView: UITextView) {
      if !updating { onSelection(textView.selectedRanges) }
    }
  }
}
