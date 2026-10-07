import SwiftUI

struct NativeRecordedControlsView: View {
  @Bindable var model: NativeRecordedModel
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Publisher recorded narration").font(.headline)
      Text(
        "Read Along follows the publisher's recorded segments. Highlighting uses segment timings."
      )
      .font(.subheadline).fixedSize(horizontal: false, vertical: true)
      if !model.isAvailable {
        Text("This ebook has no publisher recorded narration.")
          .accessibilityIdentifier("recordedNarrationUnavailable")
      } else {
        Button("Start at chosen passage", action: startCurrent)
          .accessibilityIdentifier("recordedStartPassage")
          .disabled(!model.canControl)
        Button("Resume recorded narration", action: resumeSaved)
          .accessibilityIdentifier("recordedResumeSaved")
          .disabled(!model.canControl || model.position.saved == nil)
        if model.clip != nil {
          Text(model.segment?.text ?? "Recorded segment")
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("recordedSegmentText")
          Text(model.timeLabel).font(.subheadline.monospacedDigit())
            .accessibilityIdentifier("recordedSegmentTime")
          ViewThatFits(in: .horizontal) {
            HStack { transport }
            VStack(alignment: .leading) { transport }
          }
          TextField("Seconds within segment", text: $model.seekSeconds)
            .textFieldStyle(.roundedBorder).keyboardType(.decimalPad)
            .accessibilityIdentifier("recordedSeekSeconds")
          Button("Seek within segment", action: seek)
            .disabled(!model.canControl).accessibilityIdentifier("recordedSeek")
        }
        Toggle("Follow recorded text", isOn: Binding(get: { model.follow }, set: setFollow))
          .disabled(!model.canControl).accessibilityIdentifier("recordedFollow")
        Picker("Playback speed", selection: Binding(get: { model.rate }, set: setRate)) {
          ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0, 4.0], id: \.self) { value in
            Text("\(value.formatted())×").tag(value)
          }
        }
        .disabled(!model.canControl).accessibilityIdentifier("recordedRate")
      }
      if model.isBusy { ProgressView("Preparing recorded narration…") }
      if let error = model.error {
        Text(error).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("recordedNarrationError")
      }
      if let message = model.position.message {
        Text(message).fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("recordedSyncError")
        Button("Retry recorded position save", action: retrySave)
          .disabled(model.isBusy || model.position.isSaving)
          .accessibilityIdentifier("recordedRetrySave")
      }
    }
    .buttonStyle(.bordered).controlSize(.large).padding()
  }

  @ViewBuilder private var transport: some View {
    Button("Previous segment", action: previous).disabled(!model.canControl)
      .accessibilityIdentifier("recordedPreviousSegment")
    Button(model.isPlaying ? "Pause recording" : "Play recording", action: toggle)
      .disabled(!model.canControl).accessibilityIdentifier("recordedToggle")
    Button("Next segment", action: next).disabled(!model.canControl)
      .accessibilityIdentifier("recordedNextSegment")
    Button("Stop recording", action: stop).disabled(!model.canControl)
      .accessibilityIdentifier("recordedStop")
  }

  private func startCurrent() { Task { await model.startCurrent() } }
  private func resumeSaved() { Task { await model.resumeSaved() } }
  private func toggle() { Task { await model.togglePlayback() } }
  private func previous() { Task { await model.moveClip(forward: false) } }
  private func next() { Task { await model.moveClip(forward: true) } }
  private func stop() { Task { _ = await model.stopAndSave() } }
  private func seek() { Task { await model.seek() } }
  private func setFollow(_ value: Bool) { Task { await model.setFollow(value) } }
  private func setRate(_ value: Double) { model.setRate(value) }
  private func retrySave() { Task { _ = await model.position.flush() } }
}
