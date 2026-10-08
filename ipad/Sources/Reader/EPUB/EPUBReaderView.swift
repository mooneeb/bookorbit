import SwiftUI

struct EPUBReaderView: View {
  @State private var model: EPUBReaderModel
  @State private var speech: NativeTTSModel
  @State private var recorded: NativeRecordedModel
  @State private var bridge: NativeContinuationModel
  private let offersContinuation: Bool
  @State private var showingContents = false
  @State private var showingSearch = false
  @State private var showingSettings = false
  @State private var showingBookmarks = false
  @State private var confirmsDiscard = false
  @State private var showingSpeech = false
  @State private var showingRecorded = false
  @State private var showingPosition = false
  @State private var isReaderAction = false
  @ScaledMetric(relativeTo: .caption) private var feedbackHeight = 44
  @Environment(\.dismiss) private var dismiss
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.scenePhase) private var scenePhase

  init(
    api: BookOrbitAPI, bookID: Int, file: BookDetailFile,
    title: String = "Ebook", language: String? = nil,
    files: [BookDetailFile] = [], continuation: BookContinuationTarget? = nil,
    onContinue: (@MainActor (NativeContinuationDestination) -> Void)? = nil
  ) {
    let reader = EPUBReaderModel(api: api, bookID: bookID, file: file, continuation: continuation)
    _model = State(initialValue: reader)
    let speech = NativeTTSModel(
      api: api, bookID: bookID, fileID: file.id,
      title: title, language: language, source: reader)
    let recorded = NativeRecordedModel(reader: reader, title: title)
    recorded.beforePlayback = { [weak speech] in await speech?.stopAndSave() ?? false }
    let bridge = NativeContinuationModel(
      api: api, bookID: bookID, direction: "text_to_audio", files: files)
    bridge.beforeResolve = { [weak reader, weak speech, weak recorded] in
      guard let reader, let speech, let recorded else { return nil }
      let savedSpeech = await speech.stopAndSave()
      let savedRecorded = await recorded.stopAndSave()
      guard savedSpeech && savedRecorded, await reader.saveProgress(),
        let cfi = reader.location?.cfi
      else { return nil }
      return BookContinuationQuery(direction: "text_to_audio", sourceFileId: file.id, textCfi: cfi)
    }
    bridge.chosen = { [weak reader, weak speech, weak recorded] destination in
      recorded?.close()
      speech?.close()
      reader?.close()
      onContinue?(destination)
    }
    offersContinuation = onContinue != nil
    _bridge = State(initialValue: bridge)
    _recorded = State(initialValue: recorded)
    _speech = State(initialValue: speech)
  }

  var body: some View {
    NavigationStack {
      ZStack {
        // WebKit needs an attached viewport to finish the initial publication layout.
        EPUBPageHost(model: model)
          .accessibilityLabel("Book content")
          .accessibilityHidden(!model.isReady)
          .allowsHitTesting(
            model.canNavigate && !speech.isActive && !recorded.isActive && !isReaderAction
              && !bridge.isPresented)
        if !model.isReady {
          VStack(spacing: 0) {
            if model.isLoading {
              ProgressView("Opening ebook…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
              ContentUnavailableView(
                "Could not open ebook", systemImage: "book.closed",
                description: Text(model.error ?? "The publication is unavailable."))
              Button("Retry opening", action: retryOpen).frame(minHeight: 44)
                .accessibilityIdentifier("epubRetryOpen")
            }
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(.background)
        }
      }
      .navigationTitle("Ebook reader")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("Close reader", action: closeReader).disabled(!canCloseReader)
            .accessibilityIdentifier("epubCloseReader")
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button("Text to speech", systemImage: "speaker.wave.2", action: openSpeech)
            .disabled(!model.isReady || isReaderAction || bridge.isPresented || speech.isClosing)
            .accessibilityIdentifier("epubTextToSpeech")
        }
        ToolbarItem(placement: .topBarTrailing) {
          Menu("Reader tools", systemImage: "ellipsis.circle") {
            if offersContinuation {
              Button("Continue listening", action: openContinuation)
                .accessibilityIdentifier("epubContinueListening")
            }
            Button("Recorded Read Along", action: openRecorded)
              .accessibilityIdentifier("epubRecordedReadAlong")
            Button("Contents", action: openContents).accessibilityIdentifier("epubContents")
            Button("Go to position", action: openPosition).accessibilityIdentifier(
              "epubGoToPosition"
            )
            .keyboardShortcut("l", modifiers: .command)
            Button("Previous section", action: previousSection)
              .disabled(!model.canGoToPreviousSection)
              .keyboardShortcut(.upArrow, modifiers: .command)
              .accessibilityIdentifier("epubPreviousSection")
            Button("Next section", action: nextSection)
              .disabled(!model.canGoToNextSection)
              .keyboardShortcut(.downArrow, modifiers: .command)
              .accessibilityIdentifier("epubNextSection")
            Button("Search book", action: openSearch).accessibilityIdentifier("epubSearch")
            Button("Bookmarks", action: openBookmarks).accessibilityIdentifier("epubBookmarks")
            Button("Reader settings", action: openSettings).accessibilityIdentifier("epubSettings")
          }
          .disabled(!model.canNavigate || isReaderAction || bridge.isPresented)
          .accessibilityIdentifier("epubReaderTools")
        }
      }
      .safeAreaInset(edge: .bottom) {
        VStack(spacing: 8) {
          if speech.isActive || speech.position.message != nil {
            speechStatus
          }
          if recorded.isActive || recorded.position.message != nil {
            ViewThatFits(in: .horizontal) {
              HStack { recordedStatus }
              VStack { recordedStatus }
            }
          }
          if model.location != nil {
            Text(model.positionText)
              .font(.caption).accessibilityIdentifier("epubReadingPosition")
          }
          // Save feedback must not resize the publication and trigger another relocation/save.
          readerFeedback
          if model.selectionCFI != nil {
            Button("Bookmark selected passage", action: openBookmarks).frame(minHeight: 44)
              .accessibilityIdentifier("epubBookmarkSelection")
              .disabled(!model.canNavigate || isReaderAction || bridge.isPresented)
          }
          ViewThatFits(in: .horizontal) {
            HStack { navigationButtons }
            VStack { navigationButtons }
          }
        }
        .buttonStyle(.plain).padding(.horizontal).padding(.vertical, 8).background(.background)
      }
    }
    .task {
      model.setReduceMotion(reduceMotion)
      await model.load()
      if model.isReady {
        await recorded.open()
        await speech.open()
      }
    }
    .onChange(of: reduceMotion) { _, value in model.setReduceMotion(value) }
    .onChange(of: dynamicTypeSize) { _, _ in applySettings() }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active {
        Task {
          await speech.foreground()
          await recorded.foreground()
        }
      }
      if phase == .background {
        bridge.cancel()
        speech.background()
        Task { _ = await recorded.stopAndSave() }
      }
    }
    .onDisappear {
      if !showingContents && !showingSearch && !showingSettings && !showingBookmarks
        && !showingSpeech && !showingRecorded && !showingPosition && !bridge.isPresented
      {
        Task {
          bridge.cancel()
          _ = await recorded.stopAndSave()
          recorded.close()
          speech.close()
          model.close()
        }
      }
    }
    .sheet(isPresented: $bridge.isPresented, onDismiss: bridge.cancel) {
      NativeContinuationView(model: bridge)
    }
    .sheet(isPresented: $showingPosition) {
      EPUBPositionNavigationView(reader: model, onJump: jumpToPosition)
    }
    .sheet(isPresented: $showingSpeech) {
      NavigationStack {
        ScrollView { NativeTTSControlsView(model: speech) }
          .navigationTitle("System speech")
          .navigationBarTitleDisplayMode(.inline)
          .toolbar {
            ToolbarItem(placement: .confirmationAction) {
              Button("Done", action: closeSpeech)
                .accessibilityIdentifier("nativeTTSCloseControls")
            }
          }
      }
    }
    .sheet(isPresented: $showingRecorded) {
      NavigationStack {
        ScrollView { NativeRecordedControlsView(model: recorded) }
          .navigationTitle("Recorded Read Along").navigationBarTitleDisplayMode(.inline)
          .toolbar {
            ToolbarItem(placement: .confirmationAction) {
              Button("Done", action: closeRecorded).accessibilityIdentifier("recordedCloseControls")
            }
          }
      }
    }
    .fullScreenCover(isPresented: $showingContents) { EPUBContentsView(model: model) }
    .fullScreenCover(isPresented: $showingSearch) { EPUBSearchView(model: model) }
    .fullScreenCover(isPresented: $showingSettings, onDismiss: applySettings) {
      EPUBPreferencesView(model: model.preferences)
    }
    .fullScreenCover(isPresented: $showingBookmarks) {
      if let cfi = model.selectionCFI ?? model.location?.cfi {
        EPUBBookmarksView(
          api: model.api, bookID: model.bookID, cfi: cfi,
          defaultTitle: model.selectionText.isEmpty
            ? "Chapter \((model.location?.chapterIndex ?? 0) + 1)"
            : String(model.selectionText.prefix(200))
        ) { target in
          navigate { await model.goToCFI(target) }
        }
      }
    }
    .interactiveDismissDisabled(
      !canCloseReader || model.hasPendingSave || speech.isActive || speech.position.hasPendingSave
        || recorded.isActive || recorded.position.hasPendingSave
    )
    .alert("Close without saving?", isPresented: $confirmsDiscard) {
      Button("Keep reading", role: .cancel) {}
      Button("Close without saving", role: .destructive, action: discardAndClose)
    } message: {
      Text(
        "The latest server save was not confirmed. Closing uses the last confirmed reading position. Pending speech and recorded narration positions stay on this iPad and retry sync when reopened."
      )
    }
  }

  private var canCloseReader: Bool {
    model.canClose && !isReaderAction && !bridge.isPresented && !speech.isClosing
      && !speech.isStopping
      && !speech.preferences.isSaving && !speech.position.isSaving
      && !recorded.isBusy && !recorded.position.isSaving
  }

  @ViewBuilder private var recordedStatus: some View {
    Text("Recorded narration: \(recorded.state.rawValue)").font(.caption)
      .accessibilityIdentifier("epubRecordedState")
    Button(recorded.isPlaying ? "Pause recording" : "Play recording", action: toggleRecorded)
      .frame(minHeight: 44).disabled(!recorded.canControl)
      .accessibilityIdentifier("epubRecordedToggle")
    Button("Recorded controls", action: openRecorded).frame(minHeight: 44)
      .accessibilityIdentifier("epubRecordedControls")
    if let message = recorded.position.message {
      Text(message).font(.caption).fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("epubRecordedSyncError")
    }
  }

  private var speechStatus: some View {
    VStack(alignment: .leading, spacing: 4) {
      if speech.isActive {
        Text(
          speech.currentWord.isEmpty ? "Speech is \(speech.state.rawValue)." : speech.currentWord
        )
        .font(.body.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("epubSpeechCurrentWord")
      }
      if let message = speech.position.message {
        Text(message).font(.caption).fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("epubSpeechSyncError")
      }
      ViewThatFits(in: .horizontal) {
        HStack { speechStatusButtons }
        VStack(alignment: .leading) { speechStatusButtons }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var speechStatusButtons: some View {
    Group {
      Button("Speech controls", action: openSpeech).frame(minHeight: 44)
        .accessibilityIdentifier("epubSpeechControls")
      if speech.isActive {
        Button(
          speech.isPlaying || speech.state == .loading ? "Pause speech" : "Resume speech",
          action: toggleSpeech
        )
        .frame(minHeight: 44)
        .disabled(speech.isClosing || speech.isStopping || isReaderAction || bridge.isPresented)
        .keyboardShortcut(.space, modifiers: [.command, .shift])
        .accessibilityIdentifier("epubSpeechToggle")
        Button("Stop speech to navigate", action: stopSpeech).frame(minHeight: 44)
          .disabled(speech.isClosing || speech.isStopping || isReaderAction || bridge.isPresented)
          .keyboardShortcut(".", modifiers: [.command, .shift])
          .accessibilityIdentifier("epubStopSpeech")
      }
    }
  }

  @ViewBuilder private var navigationButtons: some View {
    Button("Previous page", action: previousPage).frame(minWidth: 44, minHeight: 44)
      .disabled(!model.canNavigate || isReaderAction || bridge.isPresented).accessibilityIdentifier(
        "epubPreviousPage"
      )
      .keyboardShortcut(model.rightToLeft ? .rightArrow : .leftArrow, modifiers: [])
    Spacer(minLength: 12)
    Button(action: savePosition) {
      Text("Save position").hidden().overlay {
        Text(model.hasPendingSave ? "Retry Save" : "Save position")
      }
    }
    .frame(minWidth: 44, minHeight: 44).disabled(
      !model.canSave || isReaderAction || bridge.isPresented
    )
    .accessibilityLabel(model.hasPendingSave ? "Retry Save" : "Save position")
    .accessibilityIdentifier("epubSavePosition")
    Spacer(minLength: 12)
    Button("Next page", action: nextPage).frame(minWidth: 44, minHeight: 44)
      .disabled(!model.canNavigate || isReaderAction || bridge.isPresented).accessibilityIdentifier(
        "epubNextPage"
      )
      .keyboardShortcut(model.rightToLeft ? .leftArrow : .rightArrow, modifiers: [])
  }

  private var readerFeedback: some View {
    ScrollView {
      VStack(spacing: 8) {
        if let failure = model.fontFailure {
          Text(failure).font(.caption).fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("epubFontFailure")
        }
        if let error = model.error, model.isReady {
          Text(error).font(.caption).fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("epubReaderError")
        }
        if let status = model.status {
          Text(status).font(.caption).fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("epubReaderStatus")
        }
      }
      .frame(maxWidth: .infinity)
    }
    .frame(height: feedbackHeight)
    .scrollBounceBehavior(.basedOnSize)
  }

  private func previousPage() { navigate { await model.turn(forward: false) } }
  private func nextPage() { navigate { await model.turn(forward: true) } }
  private func previousSection() {
    guard model.canGoToPreviousSection, let index = model.location?.chapterIndex else { return }
    navigate { await model.goToChapter(index - 1) }
  }
  private func nextSection() {
    guard model.canGoToNextSection, let index = model.location?.chapterIndex else { return }
    navigate { await model.goToChapter(index + 1) }
  }
  private func openPosition() {
    guard model.canNavigate, !isReaderAction, !bridge.isPresented else { return }
    showingPosition = true
  }
  private func jumpToPosition(_ fraction: Double) async -> EPUBPositionJumpResult {
    guard model.canNavigate, !isReaderAction, !bridge.isPresented,
      !speech.isClosing, !speech.isStopping, !speech.preferences.isSaving
    else { return .failed }
    isReaderAction = true
    defer { isReaderAction = false }
    guard await recorded.stopAndSave(), await speech.stopAndSave() else { return .failed }
    return await model.goToFraction(fraction)
  }
  private func savePosition() { Task { await model.saveProgress() } }
  private func retryOpen() {
    Task {
      await model.load()
      if model.isReady {
        await recorded.open()
        await speech.open()
      }
    }
  }
  private func openContents() { navigate { showingContents = true } }
  private func openSearch() { navigate { showingSearch = true } }
  private func openSettings() { navigate { showingSettings = true } }
  private func openBookmarks() { navigate { showingBookmarks = true } }
  private func applySettings() { navigate { await model.applyPreferences() } }
  private func openContinuation() { Task { await bridge.open() } }
  private func openSpeech() {
    Task { if await recorded.stopAndSave() { showingSpeech = true } }
  }
  private func openRecorded() {
    Task { if await speech.stopAndSave() { showingRecorded = true } }
  }
  private func closeRecorded() { showingRecorded = false }
  private func toggleRecorded() { Task { await recorded.togglePlayback() } }
  private func closeSpeech() { showingSpeech = false }
  private func stopSpeech() { navigate {} }
  private func toggleSpeech() {
    Task { if await recorded.stopAndSave() { await speech.togglePlayback() } }
  }

  private func navigate(_ action: @escaping @MainActor () async -> Void) {
    Task {
      guard !isReaderAction, !speech.isClosing, !speech.preferences.isSaving else { return }
      isReaderAction = true
      defer { isReaderAction = false }
      guard await recorded.stopAndSave() else { return }
      await speech.navigateReader(action)
    }
  }

  private func discardAndClose() {
    bridge.cancel()
    recorded.close()
    speech.close()
    model.discardPendingProgress()
    model.close()
    dismiss()
  }
  private func closeReader() {
    Task {
      guard canCloseReader else { return }
      isReaderAction = true
      defer { isReaderAction = false }
      if !model.isReady {
        recorded.close()
        speech.close()
        model.close()
        dismiss()
        return
      }
      let savedSpeech = await speech.finish()
      let savedRecorded = await recorded.stopAndSave()
      let savedReader = await model.saveProgress()
      if savedSpeech && savedRecorded && savedReader {
        recorded.close()
        speech.close()
        model.close()
        dismiss()
      } else {
        confirmsDiscard = true
      }
    }
  }
}
