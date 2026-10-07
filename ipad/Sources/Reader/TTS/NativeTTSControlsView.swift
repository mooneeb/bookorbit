import SwiftUI

struct NativeTTSControlsView: View {
  let model: NativeTTSModel
  @State private var showSettings = false
  @State private var showPassage = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline) {
        Text("Text to speech").font(.headline)
        Spacer()
        Text(stateLabel).font(.subheadline).foregroundStyle(.secondary)
          .accessibilityIdentifier("nativeTTSState")
      }
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 12) { playbackButtons }
        VStack(alignment: .leading, spacing: 8) { playbackButtons }
      }
      if !model.currentWord.isEmpty {
        Text(model.currentWord).font(.body.weight(.semibold))
          .accessibilityLabel("Current spoken word")
          .accessibilityValue(model.currentWord)
          .accessibilityIdentifier("nativeTTSCurrentWord")
      }
      if let chapter = model.position.savedPosition?.chapterIndex {
        Text("Speech chapter \(chapter + 1)").font(.caption)
          .accessibilityIdentifier("nativeTTSChapter")
      }
      if let summary = model.speechSummary {
        Text(summary)
          .font(.caption).foregroundStyle(.secondary)
          .accessibilityIdentifier("nativeTTSVoiceSummary")
      }
      if let message = model.timingMessage {
        feedback(message, identifier: "nativeTTSTimingStatus")
      }
      if let message = model.voiceMessage {
        feedback(message, identifier: "nativeTTSVoiceAvailability")
      }
      if model.voices.isEmpty, model.hasLoaded {
        Button("Refresh system voices", action: refreshVoices)
          .frame(minHeight: 44).accessibilityIdentifier("nativeTTSRefreshVoices")
      }
      if let message = model.rateMessage { feedback(message, identifier: "nativeTTSRateLimit") }
      if let error = model.error ?? model.preferences.error {
        feedback(error, identifier: "nativeTTSError")
        Button("Retry speech", action: retry)
          .frame(minHeight: 44)
          .disabled(model.isClosing || model.isStopping || model.isReaderNavigating)
          .accessibilityIdentifier("nativeTTSRetry")
      }
      if let message = model.position.message {
        feedback(message, identifier: "nativeTTSSyncError")
        Button("Retry position sync", action: retrySync)
          .frame(minHeight: 44).disabled(model.position.isSaving)
          .accessibilityIdentifier("nativeTTSSyncRetry")
      }
      if model.position.hasPendingSave {
        Text(
          model.position.isSaving
            ? "Syncing speech position…" : "Speech position is kept on this iPad."
        )
        .font(.caption).accessibilityIdentifier("nativeTTSPendingPosition")
      }
      if !model.currentPassage.isEmpty {
        DisclosureGroup("Spoken passage", isExpanded: $showPassage) {
          Text(model.currentPassage).font(.body).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("nativeTTSPassage")
        }
        .animation(reduceMotion ? nil : .default, value: showPassage)
      }
    }
    .padding()
    .background(Color(uiColor: .secondarySystemBackground))
    .clipShape(RoundedRectangle(cornerRadius: 12))
    .sheet(isPresented: $showSettings, onDismiss: settingsClosed) {
      NativeTTSSettingsView(model: model)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("nativeTTSControls")
  }

  private var playbackButtons: some View {
    Group {
      Button(playbackLabel, action: toggle)
        .frame(minWidth: 44, minHeight: 44)
        .disabled(
          model.isClosing || model.isStopping || model.isReaderNavigating
            || (!model.canStart && !model.isPlaying && model.state != .loading)
        )
        .keyboardShortcut(.space, modifiers: [.command, .shift])
        .accessibilityIdentifier("nativeTTSToggle")
      Button("Stop speech", action: stop)
        .frame(minWidth: 44, minHeight: 44).disabled(!model.canStop)
        .keyboardShortcut(".", modifiers: [.command, .shift])
        .accessibilityIdentifier("nativeTTSStop")
      Menu {
        Button("Speak from this passage", action: startCurrent)
          .disabled(!model.canStart)
          .accessibilityIdentifier("nativeTTSStartCurrent")
        if model.position.savedPosition != nil {
          Button("Resume saved speech passage", action: resumeSaved)
            .disabled(!model.canStart)
            .accessibilityIdentifier("nativeTTSResumeSaved")
        }
        Button("Speech settings", action: openSettings)
          .disabled(!model.canChangeSettings)
          .accessibilityIdentifier("nativeTTSOpenSettings")
      } label: {
        Label("Speech options", systemImage: "ellipsis.circle")
      }
      .frame(minWidth: 44, minHeight: 44)
      .accessibilityIdentifier("nativeTTSOptions")
    }
    .buttonStyle(.bordered)
  }

  private var stateLabel: String {
    if model.isStopping { return "Stopping" }
    if !model.hasLoaded { return model.error == nil ? "Loading" : "Unavailable" }
    if model.server.isPreviewing { return "Voice preview" }
    if model.preferences.useServer ? model.effectiveServerVoice == nil : model.voices.isEmpty {
      return "Unavailable"
    }
    if model.reachedEnd { return "Book finished" }
    switch model.state {
    case .idle: return "Stopped"
    case .loading: return "Loading passage"
    case .playing: return "Speaking"
    case .paused: return "Paused"
    case .error: return "Unavailable"
    }
  }

  private var playbackLabel: String {
    if model.isPlaying || model.state == .loading { return "Pause speech" }
    if model.state == .paused { return "Resume speech" }
    return model.position.savedPosition == nil ? "Play speech" : "Resume saved speech"
  }

  private func feedback(_ text: String, identifier: String) -> some View {
    Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
      .accessibilityIdentifier(identifier)
  }

  private func toggle() { Task { await model.togglePlayback() } }
  private func stop() { Task { await model.stop() } }
  private func startCurrent() { Task { await model.startFromCurrentPosition() } }
  private func resumeSaved() { Task { await model.resumeSavedPosition() } }
  private func retry() { Task { await model.retry() } }
  private func retrySync() { Task { _ = await model.position.flush() } }
  private func openSettings() {
    Task { if await model.beginSettings() { showSettings = true } }
  }
  private func settingsClosed() { Task { await model.settingsClosed() } }
  private func refreshVoices() { Task { await model.foreground() } }
}
