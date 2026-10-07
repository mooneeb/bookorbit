import SwiftUI

struct AudioSettingsView: View {
  let model: AudioPlayerModel
  @Environment(\.dismiss) private var dismiss
  @State private var draft: AudioReaderSettings

  init(model: AudioPlayerModel) {
    self.model = model
    _draft = State(initialValue: model.preferences.value)
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("Playback") {
          Stepper(
            "Speed: \(draft.playbackSpeed, specifier: "%.2f")x",
            value: $draft.playbackSpeed, in: 0.5...3, step: 0.05
          )
          .accessibilityIdentifier("audiobookPlaybackSpeed")
          Slider(value: $draft.volume, in: 0...1) {
            Text("Volume")
          }.accessibilityIdentifier("audiobookVolume")
        }
        Section("Skip intervals") {
          Stepper(
            "Back: \(Int(draft.skipBackSeconds)) seconds", value: $draft.skipBackSeconds,
            in: 0...max(120, draft.skipBackSeconds), step: 5
          ).accessibilityIdentifier("audiobookSkipBackSetting")
          Stepper(
            "Forward: \(Int(draft.skipForwardSeconds)) seconds", value: $draft.skipForwardSeconds,
            in: 0...max(120, draft.skipForwardSeconds), step: 5
          ).accessibilityIdentifier("audiobookSkipForwardSetting")
        }
        Section {
          Text(
            model.preferences.syncSettings
              ? "These settings are synchronized with your account."
              : "These settings apply to your audiobooks on this iPad.")
          Button("Use standard settings") { draft = .readerDefault }
            .frame(minHeight: 44)
            .disabled(!model.preferences.canSave)
            .accessibilityIdentifier("audiobookStandardSettings")
          if let error = model.preferences.error {
            Text(error).accessibilityIdentifier("audiobookSettingsSaveError")
          }
        }
      }
      .disabled(model.preferences.isSaving)
      .navigationTitle("Audio settings")
      .safeAreaInset(edge: .bottom) {
        HStack {
          Button("Cancel", action: dismiss.callAsFunction)
            .font(.body).frame(minWidth: 44, minHeight: 44)
            .disabled(model.preferences.isSaving).accessibilityIdentifier("audiobookSettingsCancel")
          Spacer()
          Button(model.preferences.isSaving ? "Saving…" : "Save") {
            Task { if await model.saveSettings(draft) { dismiss() } }
          }
          .font(.body).frame(minWidth: 44, minHeight: 44)
          .disabled(!draft.isValid || !model.preferences.canSave)
          .accessibilityIdentifier("audiobookSettingsSave")
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color(uiColor: .label))
        .padding(.horizontal)
        .background(Color(uiColor: .systemBackground))
      }
    }
    .interactiveDismissDisabled(model.preferences.isSaving)
  }
}
