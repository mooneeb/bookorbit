import SwiftUI
import UIKit

struct NativeChapterView: View {
  @State private var model: NativeChapterModel
  @Environment(\.dismiss) private var dismiss

  init(api: BookOrbitAPI, bookID: Int, file: BookDetailFile) {
    _model = State(initialValue: NativeChapterModel(api: api, bookID: bookID, file: file))
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        if let chapter = model.chapter {
          NativeChapterTextView(chapter: chapter)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = model.error {
          Text(error)
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          ProgressView("Opening chapter…")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        Button("Close chapter", action: dismiss.callAsFunction)
          .frame(maxWidth: .infinity, minHeight: 44)
          .contentShape(Rectangle())
          .padding()
      }
      .font(.body)
      .foregroundStyle(.primary)
      .buttonStyle(.plain)
      .background(.background)
      .navigationTitle("Native chapter diagnostic")
      .navigationBarTitleDisplayMode(.inline)
    }
    .task { await model.load() }
    .onDisappear { model.close() }
  }
}

private struct NativeChapterTextView: UIViewRepresentable {
  let chapter: NativeChapterDocument

  func makeUIView(context: Context) -> UITextView {
    let view = UITextView(usingTextLayoutManager: true)
    view.isEditable = false
    view.isSelectable = true
    view.backgroundColor = .systemBackground
    view.textColor = .label
    let descriptor = UIFont.systemFont(ofSize: 20).fontDescriptor
    let base = UIFont(descriptor: descriptor.withDesign(.serif) ?? descriptor, size: 20)
    view.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: base)
    view.adjustsFontForContentSizeCategory = true
    view.textContainerInset = UIEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
    view.textContainer.lineFragmentPadding = 0
    view.accessibilityIdentifier = "nativeChapter"
    return view
  }

  func updateUIView(_ view: UITextView, context: Context) {
    view.accessibilityLanguage = chapter.language
    if !view.text.utf16.elementsEqual(chapter.text.utf16) {
      let paragraph = NSMutableParagraphStyle()
      paragraph.lineHeightMultiple = 1.5
      paragraph.paragraphSpacing = 20
      view.attributedText = NSAttributedString(
        string: chapter.text,
        attributes: [
          .font: view.font ?? UIFont.preferredFont(forTextStyle: .body),
          .foregroundColor: UIColor.label,
          .paragraphStyle: paragraph,
        ])
    }
  }
}
