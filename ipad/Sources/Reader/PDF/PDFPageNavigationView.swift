import SwiftUI

struct PDFPageNavigationView: View {
  let pageCount: Int
  let onNavigate: (Int) -> Void
  @State private var pageText: String
  @FocusState private var pageIsFocused: Bool
  @Environment(\.dismiss) private var dismiss

  init(currentPage: Int, pageCount: Int, onNavigate: @escaping (Int) -> Void) {
    self.pageCount = pageCount
    self.onNavigate = onNavigate
    _pageText = State(initialValue: String(currentPage))
  }

  private var destination: Int? {
    guard let page = Int(pageText.trimmingCharacters(in: .whitespacesAndNewlines)),
      (1...pageCount).contains(page)
    else { return nil }
    return page - 1
  }

  var body: some View {
    NavigationStack {
      Form {
        LabeledContent("Page") {
          TextField("Page", text: $pageText)
            .keyboardType(.numbersAndPunctuation)
            .focused($pageIsFocused)
            .accessibilityLabel("Page")
            .accessibilityIdentifier("pdfDestinationPage")
            .onSubmit(navigate)
        }
        Text("Enter a page from 1 to \(pageCount).")
      }
      .navigationTitle("Go to page")
      .navigationBarTitleDisplayMode(.inline)
      .safeAreaInset(edge: .bottom) {
        HStack {
          Button("Cancel", action: dismiss.callAsFunction)
          Spacer()
          Button(action: navigate) {
            Label(
              "Go to page",
              systemImage: destination == nil ? "exclamationmark.circle" : "arrow.right")
          }
          .accessibilityElement(children: .combine)
          .accessibilityIdentifier("pdfGoToPage")
          .disabled(destination == nil)
        }
        .buttonStyle(PDFNavigationActionButtonStyle())
        .font(.body)
        .padding(.horizontal)
        .background(.background)
      }
      .toolbar {
        ToolbarItemGroup(placement: .keyboard) {
          Spacer()
          Button("Hide keyboard") { pageIsFocused = false }
            .accessibilityIdentifier("pdfDismissKeyboard")
        }
      }
    }
  }

  private func navigate() {
    guard let destination else { return }
    onNavigate(destination)
    dismiss()
  }
}

private struct PDFNavigationActionButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(Color(uiColor: .label))
      .padding(.vertical, 10)
      .frame(minHeight: 44)
      .contentShape(Rectangle())
      .opacity(configuration.isPressed ? 0.7 : 1)
  }
}
