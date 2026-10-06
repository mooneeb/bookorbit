import SwiftUI

struct ReaderPageNavigationView: View {
  let pageCount: Int
  let onNavigate: (Int) -> Void
  let identifierPrefix: String
  @State private var pageText: String
  @FocusState private var pageIsFocused: Bool
  @Environment(\.dismiss) private var dismiss

  init(
    currentPage: Int, pageCount: Int, identifierPrefix: String = "pdf",
    onNavigate: @escaping (Int) -> Void
  ) {
    self.pageCount = pageCount
    self.onNavigate = onNavigate
    self.identifierPrefix = identifierPrefix
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
            .accessibilityIdentifier("\(identifierPrefix)DestinationPage")
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
          .accessibilityIdentifier("\(identifierPrefix)GoToPage")
          .disabled(destination == nil)
        }
        .buttonStyle(PageNavigationActionButtonStyle())
        .font(.body)
        .padding(.horizontal)
        .background(.background)
      }
      .toolbar {
        ToolbarItemGroup(placement: .keyboard) {
          Spacer()
          Button("Hide keyboard") { pageIsFocused = false }
            .accessibilityIdentifier("\(identifierPrefix)DismissKeyboard")
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

private struct PageNavigationActionButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(Color(uiColor: .label))
      .padding(.vertical, 10)
      .frame(minHeight: 44)
      .contentShape(Rectangle())
      .opacity(configuration.isPressed ? 0.7 : 1)
  }
}
