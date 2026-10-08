import SwiftUI
import UIKit

struct BookReadingView: View {
  let acknowledged: (BookDetail) -> Void
  let saved: (BookDetail) -> Void
  @State private var model: BookReadingModel
  @FocusState private var noteIsFocused: Bool
  @Environment(\.dismiss) private var dismiss

  init(
    api: BookOrbitAPI, book: BookDetail, acknowledged: @escaping (BookDetail) -> Void,
    saved: @escaping (BookDetail) -> Void
  ) {
    self.acknowledged = acknowledged
    self.saved = saved
    _model = State(initialValue: BookReadingModel(api: api, book: book))
  }

  var body: some View {
    VStack(spacing: 0) {
      Text("Your reading").font(.title2).fixedSize(horizontal: false, vertical: true)
        .accessibilityAddTraits(.isHeader).padding()
      ScrollViewReader { scroll in
        ScrollView {
          VStack(alignment: .leading, spacing: 24) {
            if let draft = model.draft {
              BookReadingFields(draft: draft, noteFocus: $noteIsFocused)
            } else if model.isLoading {
              ProgressView("Loading your reading details…")
            }
            if let error = model.error {
              Text(error).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("bookReadingError")
              if model.draft == nil {
                Button {
                  Task { await model.load() }
                } label: {
                  Text("Try again").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                }.accessibilityIdentifier("bookReadingRetry")
              }
            }
          }.padding().frame(maxWidth: .infinity, alignment: .leading).disabled(model.isSaving)
        }.scrollEdgeEffectHidden().clipped()
          .onChange(of: noteIsFocused) { revealNote(using: scroll) }
          .onReceive(
            NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)
          ) {
            _ in revealNote(using: scroll)
          }
      }
      HStack {
        Button(action: dismiss.callAsFunction) {
          Text("Cancel").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        }.disabled(model.isSaving).accessibilityIdentifier("bookReadingCancel")
        Spacer()
        Button {
          Task {
            await model.save()
            acknowledged(model.book)
            if model.isComplete { saved(model.book) }
          }
        } label: {
          Text(model.isSaving ? "Saving…" : "Save")
            .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        }
        .disabled(
          model.isSaving || model.draft?.hasChanges != true || model.draft?.validationError != nil
        )
        .accessibilityIdentifier("bookReadingSave")
      }.padding(.horizontal)
    }
    .font(.body).buttonStyle(BookReadingActionButtonStyle()).foregroundStyle(Color(uiColor: .label))
    .background(Color(uiColor: .systemBackground)).interactiveDismissDisabled(model.isSaving)
    .task { await model.load() }
  }

  private func revealNote(using scroll: ScrollViewProxy) {
    guard noteIsFocused else { return }
    scroll.scrollTo(BookReadingScrollTarget.personalNote, anchor: .bottom)
  }
}

private enum BookReadingScrollTarget: Hashable {
  case personalNote
}

private struct BookReadingActionButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.foregroundStyle(Color(uiColor: .label))
      .opacity(configuration.isPressed ? 0.7 : 1)
  }
}

private struct BookReadingFields: View {
  @Bindable var draft: BookReadingDraft
  let noteFocus: FocusState<Bool>.Binding

  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      Text("These details belong to your account.").fixedSize(horizontal: false, vertical: true)
      Picker("Reading status", selection: $draft.status) {
        ForEach(BookReadingVocabulary.statuses, id: \.self) { value in
          Text(BookReadingDraft.label(value)).tag(value)
        }
      }.pickerStyle(.inline).accessibilityIdentifier("bookReadingStatus")
        .onChange(of: draft.status, draft.statusChanged)
      date("Started", text: $draft.started, identifier: "bookReadingStarted")
      date("Finished", text: $draft.finished, identifier: "bookReadingFinished")
      Text("Use YYYY-MM-DD. Dates use your account's time zone: \(draft.timeZone.identifier).")
        .fixedSize(horizontal: false, vertical: true)
      VStack(alignment: .leading, spacing: 12) {
        BookReadingHeading(text: "Personal note")
        TextEditor(text: $draft.note).frame(minHeight: 200)
          .focused(noteFocus)
          .accessibilityLabel("Personal note").accessibilityIdentifier("bookReadingNote")
          .overlay(Rectangle().stroke(Color(uiColor: .separator)))
        Text("\(draft.note.utf16.count) / \(BookReadingVocabulary.noteMaximum) characters")
        Button {
          draft.note = ""
        } label: {
          Text("Clear note").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        }.disabled(draft.note.isEmpty).accessibilityIdentifier("bookReadingClearNote")
      }.id(BookReadingScrollTarget.personalNote)
      if let error = draft.validationError {
        Text(error).fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("bookReadingValidation")
      }
    }
  }

  private func date(_ label: String, text: Binding<String>, identifier: String) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      BookReadingHeading(text: label)
      TextField("YYYY-MM-DD", text: text).textFieldStyle(.roundedBorder)
        .textInputAutocapitalization(.never).autocorrectionDisabled()
        .accessibilityLabel(label).accessibilityIdentifier(identifier)
      Button {
        text.wrappedValue = ""
      } label: {
        Text("Clear \(label.lowercased())").frame(minWidth: 44, minHeight: 44).contentShape(
          Rectangle())
      }.disabled(text.wrappedValue.isEmpty).accessibilityIdentifier("\(identifier)Clear")
    }
  }
}

private struct BookReadingHeading: UIViewRepresentable {
  let text: String

  func makeUIView(context: Context) -> UILabel {
    let label = UILabel()
    label.adjustsFontForContentSizeCategory = true
    label.textColor = .label
    label.backgroundColor = .systemBackground
    label.numberOfLines = 0
    label.isAccessibilityElement = true
    label.accessibilityTraits = [.staticText, .header]
    return label
  }

  func updateUIView(_ label: UILabel, context: Context) {
    label.text = text
    label.font = .preferredFont(forTextStyle: .headline, compatibleWith: label.traitCollection)
  }

  func sizeThatFits(_ proposal: ProposedViewSize, uiView: UILabel, context: Context) -> CGSize? {
    uiView.sizeThatFits(
      CGSize(width: proposal.width ?? .greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
  }
}
