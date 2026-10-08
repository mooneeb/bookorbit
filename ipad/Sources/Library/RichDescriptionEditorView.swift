import SwiftUI

struct RichDescriptionEditorView: View {
  @Binding var html: String
  let isLocked: Bool
  @Environment(\.isEnabled) private var isEnabled
  @State private var state = RichDescriptionEditingState()
  @State private var isPreview = false
  @State private var isLinkPanelOpen = false
  @State private var linkText = ""
  @State private var linkError: String?

  private var canEdit: Bool { isEnabled && !isLocked && !isPreview && state.isSupported }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 8)], spacing: 8) {
        formatButton("Bold", symbol: "bold", mark: "strong", action: toggleBold)
          .keyboardShortcut("b", modifiers: .command)
        formatButton("Italic", symbol: "italic", mark: "em", action: toggleItalic)
          .keyboardShortcut("i", modifiers: .command)
        formatButton("Underline", symbol: "underline", mark: "u", action: toggleUnderline)
          .keyboardShortcut("u", modifiers: .command)
        formatButton("Strikethrough", symbol: "strikethrough", mark: "s", action: toggleStrike)
        formatButton("Bullet list", symbol: "list.bullet", mark: "ul", action: toggleBulletList)
        formatButton("Numbered list", symbol: "list.number", mark: "ol", action: toggleNumberedList)
        commandButton(
          "Outdent list item", symbol: "decrease.indent", enabled: canEdit && state.canOutdent,
          action: state.outdent)
        commandButton(
          "Indent list item", symbol: "increase.indent", enabled: canEdit && state.canIndent,
          action: state.indent)
        formatButton("Quote", symbol: "text.quote", mark: "blockquote", action: state.toggleQuote)
        commandButton("Edit link", symbol: "link", enabled: canEdit, action: openLink)
        commandButton(
          "Remove link", symbol: "link.badge.minus", enabled: canEdit && state.hasLink,
          action: removeLink)
        commandButton(
          "Undo", symbol: "arrow.uturn.backward", enabled: canEdit && state.canUndo,
          action: state.undo)
        commandButton(
          "Redo", symbol: "arrow.uturn.forward", enabled: canEdit && state.canRedo,
          action: state.redo)
        commandButton(
          "Clear formatting", symbol: "eraser", enabled: canEdit, action: clearFormatting)
        commandButton(
          isPreview ? "Edit description" : "Preview description",
          symbol: isPreview ? "pencil" : "eye",
          enabled: isEnabled, identifier: "metadataDescriptionPreviewToggle", action: togglePreview)
      }
      if isLinkPanelOpen {
        VStack(alignment: .leading, spacing: 8) {
          Text("Link URL").font(.headline)
          TextField("https://example.com", text: $linkText)
            .textFieldStyle(.roundedBorder)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
            .submitLabel(.done)
            .onSubmit(applyLink)
            .frame(minHeight: 44)
            .accessibilityLabel("Description link URL")
            .accessibilityIdentifier("metadataDescriptionLinkURL")
          if let linkError {
            Text(linkError).font(.callout).foregroundStyle(.red)
              .fixedSize(horizontal: false, vertical: true)
              .accessibilityIdentifier("metadataDescriptionLinkError")
          }
          ViewThatFits(in: .horizontal) {
            HStack { linkActions }
            VStack(alignment: .leading) { linkActions }
          }
        }
      }
      RichDescriptionInput(html: $html, state: state, isPreview: isPreview, isLocked: isLocked)
        .frame(minHeight: 180)
        .overlay(alignment: .topLeading) {
          if isPreview && html.isEmpty {
            Text("No description").foregroundStyle(.secondary).padding(16)
              .allowsHitTesting(false)
          }
        }
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(uiColor: .separator)))
      if let message = state.message {
        Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("metadataDescriptionMessage")
      }
    }
    .onAppear(perform: state.refresh)
    .onChange(of: state.contentRevision) { _, _ in closeLink() }
    .onChange(of: isLocked) { _, locked in
      if locked {
        closeLink()
        state.endEditing()
      }
    }
    .onChange(of: isEnabled) { _, enabled in
      if !enabled {
        closeLink()
        state.endEditing()
      }
    }
    .onDisappear(perform: state.endEditing)
  }

  private var linkActions: some View {
    Group {
      Button("Apply link", action: applyLink).frame(minWidth: 44, minHeight: 44)
        .accessibilityIdentifier("metadataDescriptionApplyLink")
      Button("Cancel link", action: closeLink).frame(minWidth: 44, minHeight: 44)
        .accessibilityIdentifier("metadataDescriptionCancelLink")
    }.disabled(!canEdit)
  }

  private func formatButton(
    _ label: String, symbol: String, mark: String, action: @escaping () -> Void
  ) -> some View {
    commandButton(label, symbol: symbol, enabled: canEdit, action: action)
      .background(
        state.activeMarks.contains(mark) ? Color(uiColor: .tertiarySystemFill) : .clear,
        in: RoundedRectangle(cornerRadius: 8)
      )
      .accessibilityValue(state.activeMarks.contains(mark) ? "On" : "Off")
  }

  private func commandButton(
    _ label: String, symbol: String, enabled: Bool, identifier: String? = nil,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: symbol).font(.body).frame(minWidth: 44, minHeight: 44)
        .frame(maxWidth: .infinity).contentShape(Rectangle())
    }
    .buttonStyle(.borderless)
    .disabled(!enabled)
    .accessibilityLabel(label)
    .accessibilityIdentifier(
      identifier ?? "metadataDescription\(label.filter { !$0.isWhitespace })")
  }

  private func toggleBold() { state.toggleMark("strong") }
  private func toggleItalic() { state.toggleMark("em") }
  private func toggleUnderline() { state.toggleMark("u") }
  private func toggleStrike() { state.toggleMark("s") }
  private func toggleBulletList() { state.toggleList("ul") }
  private func toggleNumberedList() { state.toggleList("ol") }

  private func togglePreview() {
    closeLink()
    state.endEditing()
    isPreview.toggle()
  }

  private func openLink() {
    state.prepareLink()
    linkText = state.link
    linkError = nil
    isLinkPanelOpen = true
  }

  private func applyLink() {
    guard canEdit else { return }
    if linkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      state.applyLink(nil)
    } else if let url = RichDescriptionHTML.linkURL(linkText) {
      state.applyLink(url)
    } else {
      linkError = "Use an http, https, or mailto link."
      return
    }
    closeLink()
  }

  private func removeLink() {
    state.applyLink(nil)
    closeLink()
  }
  private func clearFormatting() {
    state.clearFormatting()
    closeLink()
  }

  private func closeLink() {
    isLinkPanelOpen = false
    linkText = ""
    linkError = nil
  }
}
