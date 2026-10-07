import SwiftUI

struct AudiobookReaderView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.scenePhase) private var scenePhase
  @State private var model: AudioPlayerModel
  @State private var bridge: NativeContinuationModel
  private let offersContinuation: Bool
  @State private var showingSettings = false
  @State private var showingBookmarks = false
  @State private var showingCloseWarning = false
  @State private var scrubPosition = 0.0
  @State private var isScrubbing = false
  @State private var sleepMinutes = 0

  init(
    api: BookOrbitAPI, bookID: Int, file: BookDetailFile,
    files: [BookDetailFile] = [], continuation: BookContinuationTarget? = nil,
    onContinue: (@MainActor (NativeContinuationDestination) -> Void)? = nil
  ) {
    let model = AudioPlayerModel(
      api: api, bookID: bookID, fileID: file.id, continuation: continuation)
    let bridge = NativeContinuationModel(
      api: api, bookID: bookID, direction: "audio_to_text", files: files)
    bridge.beforeResolve = { [weak model] in
      guard let model, await model.beginContinuation(),
        let asset = model.engine.currentAsset, let saved = model.engine.state
      else { return nil }
      return BookContinuationQuery(
        direction: "audio_to_text", sourceFileId: asset.fileId, audioRevision: saved.revision)
    }
    bridge.cancelled = { [weak model] in model?.endContinuation() }
    bridge.chosen = { [weak model] destination in
      model?.close()
      onContinue?(destination)
    }
    offersContinuation = onContinue != nil
    _model = State(initialValue: model)
    _bridge = State(initialValue: bridge)
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 20) {
          if let manifest = model.engine.manifest {
            Text(manifest.book.title).font(.title).fixedSize(horizontal: false, vertical: true)
              .accessibilityIdentifier("audiobookTitle")
            if !manifest.book.authors.isEmpty {
              Text(manifest.book.authors.joined(separator: ", "))
                .fixedSize(horizontal: false, vertical: true)
            }
            if !manifest.book.narrators.isEmpty {
              Text("Narrated by \(manifest.book.narrators.joined(separator: ", "))")
                .fixedSize(horizontal: false, vertical: true)
            }
            playbackControls
            Text("Tracks").font(.headline).accessibilityAddTraits(.isHeader)
            ForEach(manifest.assets, id: \.assetId) { asset in
              Button {
                Task { await model.select(asset) }
              } label: {
                Label(
                  "Track \(asset.sequence + 1), \(asset.format.uppercased())",
                  systemImage: asset.assetId == model.engine.currentAsset?.assetId
                    ? "speaker.wave.2" : "music.note"
                )
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 44)
              }
              .disabled(!model.canInteract)
              .accessibilityIdentifier("audiobookTrack\(asset.sequence)")
            }
            if !manifest.chapters.isEmpty {
              Text("Chapters").font(.headline).accessibilityAddTraits(.isHeader)
              if model.chaptersAvailable {
                ForEach(manifest.chapters) { chapter in
                  Button {
                    Task { await model.selectChapter(chapter) }
                  } label: {
                    Text(chapter.title).fixedSize(horizontal: false, vertical: true)
                      .frame(minHeight: 44)
                  }
                  .disabled(!model.canInteract)
                  .accessibilityIdentifier("audiobookChapter\(chapter.sequence)")
                }
              } else {
                Text("Chapter positions are unavailable until all track durations are known.")
                  .fixedSize(horizontal: false, vertical: true)
              }
            }
          } else if model.engine.isLoading || model.preferences.isLoading {
            ProgressView("Opening audiobook…")
          } else {
            Button("Retry") { Task { await model.engine.open() } }
              .frame(minHeight: 44).accessibilityIdentifier("audiobookRetry")
          }
          if let error = model.engine.error {
            Text(error).fixedSize(horizontal: false, vertical: true)
              .accessibilityIdentifier("audiobookError")
            if model.engine.manifest != nil {
              Button("Retry playback", action: model.retryPlayback)
                .frame(minHeight: 44).disabled(
                  !model.engine.canSelectTrack || model.isChangingTrack
                )
                .accessibilityIdentifier("audiobookRetryPlayback")
            }
          }
          if let error = model.preferences.error {
            Text(error).fixedSize(horizontal: false, vertical: true)
              .accessibilityIdentifier("audiobookSettingsError")
            Button("Retry settings") {
              Task { await model.reloadSettings() }
            }
            .frame(minHeight: 44).disabled(
              model.preferences.isLoading || model.preferences.isSaving
            )
            .accessibilityIdentifier("audiobookRetrySettings")
          }
        }.padding()
      }
      .buttonStyle(.plain)
      .foregroundStyle(Color(uiColor: .label))
      .background(Color(uiColor: .systemBackground))
      .safeAreaInset(edge: .bottom) {
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 16) { footerButtons }
          VStack(alignment: .leading, spacing: 8) { footerButtons }
        }
        .frame(maxWidth: .infinity)
        .buttonStyle(.plain)
        .padding(.horizontal)
        .background(Color(uiColor: .systemBackground))
      }
      .navigationTitle("Audiobook")
    }
    .interactiveDismissDisabled()
    .task { await model.open() }
    .onDisappear {
      bridge.cancel()
      model.close()
    }
    .onChange(of: model.engine.positionSeconds) {
      if !isScrubbing { scrubPosition = model.engine.positionSeconds }
    }
    .onChange(of: scenePhase) {
      if scenePhase == .background {
        bridge.cancel()
        model.background()
      }
      if scenePhase == .active { Task { await model.foreground() } }
    }
    .sheet(isPresented: $bridge.isPresented, onDismiss: bridge.cancel) {
      NativeContinuationView(model: bridge)
    }
    .sheet(isPresented: $showingSettings) { AudioSettingsView(model: model) }
    .sheet(isPresented: $showingBookmarks) { AudioBookmarksView(player: model) }
    .alert("Listening position not confirmed", isPresented: $showingCloseWarning) {
      Button("Keep reader open", role: .cancel) {}
      Button("Close without saving", role: .destructive) {
        model.close()
        dismiss()
      }
    } message: {
      Text(model.closeWarning ?? "Retry Save progress to confirm your listening position.")
    }
  }

  @ViewBuilder
  private var footerButtons: some View {
    if offersContinuation {
      Button("Continue reading", action: openContinuation).frame(minHeight: 44)
        .disabled(!model.canClose || !model.engine.isReady || bridge.isPresented)
        .accessibilityIdentifier("audiobookContinueReading")
    }
    Button(action: finish) {
      Text("Done").font(.body).fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 16).frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
    }
    .disabled(!model.canClose).accessibilityIdentifier("audiobookDone")
    Button {
      showingBookmarks = true
    } label: {
      Text("Bookmarks").font(.body).fixedSize(horizontal: false, vertical: true)
        .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
    }
    .disabled(!model.canClose || model.engine.manifest == nil)
    .accessibilityIdentifier("audiobookBookmarks")
    Button {
      showingSettings = true
    } label: {
      Text("Settings").font(.body).fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 16).frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
    }
    .disabled(!model.preferences.hasLoaded || !model.canClose)
    .accessibilityIdentifier("audiobookSettings")
  }

  private var playbackControls: some View {
    VStack(alignment: .leading, spacing: 16) {
      if let current = model.engine.currentAsset, let manifest = model.engine.manifest {
        Text("Track \(current.sequence + 1) of \(manifest.assets.count)").font(.headline)
          .accessibilityIdentifier("audiobookCurrentTrack")
      }
      Text(model.engine.timeLabel).font(.title2).monospacedDigit()
        .accessibilityIdentifier("audiobookPlaybackTime")
      Slider(
        value: $scrubPosition, in: 0...max(0.001, model.engine.durationSeconds),
        onEditingChanged: scrubChanged
      )
      .disabled(!model.canInteract)
      .accessibilityLabel("Track position in seconds")
      .accessibilityValue("\(Int(scrubPosition)) seconds")
      .accessibilityIdentifier("audiobookSeek")
      ViewThatFits(in: .horizontal) {
        HStack { transportButtons }
        VStack(alignment: .leading) { transportButtons }
      }
      .font(.body)
      Button {
        Task { await model.saveProgress() }
      } label: {
        Text(model.isWriting ? "Saving…" : "Save progress").frame(minHeight: 44)
      }
      .disabled(!model.canSave).accessibilityIdentifier("audiobookSaveProgress")
      if let message = model.engine.progressMessage {
        Text(message).fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("audiobookProgressMessage")
      }
      if !model.engine.isReady {
        ProgressView("Preparing track…").accessibilityIdentifier("audiobookPreparing")
      }
      Picker("Sleep timer", selection: $sleepMinutes) {
        Text("Off").tag(0)
        ForEach([1, 15, 30, 45, 60], id: \.self) { minutes in
          Text("\(minutes) minutes").tag(minutes)
        }
      }
      .onChange(of: sleepMinutes) { model.setSleepTimer(minutes: sleepMinutes) }
      .onChange(of: model.activeSleepMinutes) {
        if model.activeSleepMinutes == nil { sleepMinutes = 0 }
      }
      .accessibilityIdentifier("audiobookSleepTimer")
    }
  }

  @ViewBuilder
  private var transportButtons: some View {
    Button {
      Task { await model.previousTrack() }
    } label: {
      Label("Previous track", systemImage: "backward.end").frame(minHeight: 44)
    }
    .disabled(!model.canInteract || !model.hasPreviousTrack)
    .accessibilityIdentifier("audiobookPreviousTrack")
    Button {
      Task { await model.skip(-model.preferences.value.skipBackSeconds) }
    } label: {
      Text("Back \(Int(model.preferences.value.skipBackSeconds)) seconds").frame(minHeight: 44)
    }
    .disabled(!model.canInteract || model.preferences.value.skipBackSeconds == 0)
    .accessibilityIdentifier("audiobookSkipBack")
    Button {
      Task { await model.togglePlayback() }
    } label: {
      Label(
        model.engine.isPlaying ? "Pause" : "Play",
        systemImage: model.engine.isPlaying ? "pause" : "play"
      )
      .frame(minWidth: 44, minHeight: 44)
    }
    .disabled(!model.canTogglePlayback).accessibilityIdentifier("audiobookPlayPause")
    Button {
      Task { await model.skip(model.preferences.value.skipForwardSeconds) }
    } label: {
      Text("Forward \(Int(model.preferences.value.skipForwardSeconds)) seconds").frame(
        minHeight: 44)
    }
    .disabled(!model.canInteract || model.preferences.value.skipForwardSeconds == 0)
    .accessibilityIdentifier("audiobookSkipForward")
    Button {
      Task { await model.nextTrack() }
    } label: {
      Label("Next track", systemImage: "forward.end").frame(minHeight: 44)
    }
    .disabled(!model.canInteract || !model.hasNextTrack)
    .accessibilityIdentifier("audiobookNextTrack")
  }

  private func scrubChanged(_ editing: Bool) {
    isScrubbing = editing
    if !editing {
      let position = min(model.engine.durationSeconds, max(0, scrubPosition))
      Task { await model.seek(to: position) }
    }
  }

  private func openContinuation() { Task { await bridge.open() } }

  private func finish() {
    Task {
      if await model.finish() {
        dismiss()
      } else if model.closeWarning != nil {
        showingCloseWarning = true
      }
    }
  }
}
