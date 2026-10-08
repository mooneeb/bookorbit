import SwiftUI

struct EPUBPinnedContentsView: View {
  let outline: EPUBContentsOutlineModel
  let canNavigate: Bool
  let canChangeLayout: Bool
  let open: (EPUBContentsEntry) -> Void
  let unpin: () -> Void
  let browse: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Button("Contents", action: browse).font(.headline)
          .disabled(!canNavigate)
          .frame(minHeight: 44).accessibilityIdentifier("epubPinnedContentsBrowse")
        Spacer(minLength: 8)
        Button("Unpin Contents", systemImage: "pin.slash", action: unpin)
          .disabled(!canChangeLayout)
          .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
          .accessibilityIdentifier("epubUnpinContents")
      }
      .padding(.horizontal, 8)
      Divider()
      EPUBContentsList(outline: outline, canNavigate: canNavigate, open: open)
    }
    .background(.background)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("epubPinnedContents")
  }
}
