import SwiftUI

struct EPUBPositionNavigationView: View {
  let reader: EPUBReaderModel
  let onJump: @MainActor (Double) async -> EPUBPositionJumpResult
  @State private var draft: EPUBPositionNavigation
  @FocusState private var inputFocused: Bool
  @Environment(\.dismiss) private var dismiss

  init(
    reader: EPUBReaderModel,
    onJump: @escaping @MainActor (Double) async -> EPUBPositionJumpResult
  ) {
    self.reader = reader
    self.onJump = onJump
    _draft = State(
      initialValue: EPUBPositionNavigation(percentage: reader.location?.percentage ?? 0))
  }

  var body: some View {
    @Bindable var draft = draft
    NavigationStack {
      List {
        Section("Current position") {
          Text(reader.positionText).fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("epubJumpCurrentPosition")
          if let current = reader.location?.locationNumber,
            let total = reader.location?.locationTotal
          {
            Text("Location \(current) of \(total)")
              .accessibilityIdentifier("epubJumpLocationCount")
          }
        }
        Section("Go to position") {
          TextField("Percentage or location", text: $draft.input)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .keyboardType(.asciiCapable).submitLabel(.go).focused($inputFocused)
            .onSubmit(commit).frame(minHeight: 44)
            .accessibilityIdentifier("epubJumpInput")
            .disabled(draft.isCommitting || draft.needsSaveConfirmation)
          Text(instructions).fixedSize(horizontal: false, vertical: true)
          Slider(value: percentage, in: 0...100, step: 0.1) {
            Text("Percentage")
          }
          .frame(minHeight: 44).accessibilityValue("\(Int(draft.percentage)) percent")
          .accessibilityIdentifier("epubJumpPercentage")
          .disabled(draft.isCommitting || draft.needsSaveConfirmation)
          Text("\(draft.percentage.formatted(.number.precision(.fractionLength(1)))) percent")
            .accessibilityIdentifier("epubJumpDraftPercentage")
          Text(
            "Move the slider or enter a position, then choose Jump. Cancel keeps your current position."
          )
          .fixedSize(horizontal: false, vertical: true)
        }
        if draft.isCommitting {
          ProgressView(
            draft.needsSaveConfirmation ? "Confirming reading position…" : "Opening position…"
          )
          .accessibilityIdentifier("epubJumpLoading")
        }
        if let failure = draft.failure {
          Text(failure).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("epubJumpError")
        }
        if draft.needsSaveConfirmation {
          Text("The passage is open. Retry Save confirms it for reopening and other readers.")
            .fixedSize(horizontal: false, vertical: true)
        }
        Section {
          Button(draft.needsSaveConfirmation ? "Retry Save" : "Jump", action: commit)
            .frame(maxWidth: .infinity, minHeight: 44)
            .disabled(
              draft.isCommitting || (!reader.canNavigate && !draft.needsSaveConfirmation)
                || (draft.needsSaveConfirmation && !reader.canSave)
            )
            .keyboardShortcut(.return, modifiers: .command)
            .accessibilityIdentifier("epubJumpCommit")
        }
      }
      .font(.body).navigationTitle("Go to position").navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(draft.needsSaveConfirmation ? "Done" : "Cancel", action: cancel)
            .frame(minWidth: 44, minHeight: 44).disabled(draft.isCommitting)
            .keyboardShortcut(.cancelAction).accessibilityIdentifier("epubJumpCancel")
        }
      }
    }
    .interactiveDismissDisabled(draft.isCommitting)
  }

  private var percentage: Binding<Double> {
    Binding(get: { draft.percentage }, set: draft.setPercentage)
  }

  private var instructions: String {
    if let total = reader.location?.locationTotal {
      return
        "Enter 0 to 100 percent, or p1 to p\(total). Locations follow the publication text and stay independent of displayed pages."
    }
    return
      "Enter a percentage from 0 to 100. Location numbers are unavailable for this publication."
  }

  private func cancel() { dismiss() }

  private func commit() {
    inputFocused = false
    Task {
      let saved = await draft.commit(
        locationTotal: reader.location?.locationTotal, action: onJump,
        retrySave: reader.saveProgress, failureMessage: { reader.error })
      if saved { dismiss() }
    }
  }
}
