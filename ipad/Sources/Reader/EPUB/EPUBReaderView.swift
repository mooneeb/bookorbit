import SwiftUI

struct EPUBReaderView: View {
  @State private var model: EPUBReaderModel
  @State private var speech: NativeTTSModel
  @State private var recorded: NativeRecordedModel
  @State private var bridge: NativeContinuationModel
  @State private var selectionTools: EPUBSelectionToolsModel
  @State private var chrome: EPUBChromeModel
  @State private var outline = EPUBContentsOutlineModel()
  @State private var initialSearchQuery = ""
  private let language: String?
  private let offersContinuation: Bool
  @State private var positionReset: NativePositionResetModel?
  @State private var showingContents = false
  @State private var showingSearch = false
  @State private var showingSettings = false
  @State private var showingBookmarks = false
  @State private var confirmsDiscard = false
  @State private var showingSpeech = false
  @State private var showingRecorded = false
  @State private var showingPosition = false
  @State private var showingHelp = false
  @State private var contentsMessage: String?
  @State private var footerContentHeight: CGFloat = 120
  @State private var hidesControlsAfterNavigation = false
  @State private var isReaderAction = false
  @ScaledMetric(relativeTo: .caption) private var feedbackHeight = 44
  @Environment(\.dismiss) private var dismiss
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.scenePhase) private var scenePhase
  @AccessibilityFocusState private var restoreControlsFocused: Bool

  init(
    api: BookOrbitAPI, bookID: Int, file: BookDetailFile,
    title: String = "Ebook", language: String? = nil,
    files: [BookDetailFile] = [], continuation: BookContinuationTarget? = nil,
    onContinue: (@MainActor (NativeContinuationDestination) -> Void)? = nil
  ) {
    let reader = EPUBReaderModel(api: api, bookID: bookID, file: file, continuation: continuation)
    _model = State(initialValue: reader)
    _chrome = State(initialValue: EPUBChromeModel(api: api, fileID: file.id))
    self.language = language
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
    let selectionTools = EPUBSelectionToolsModel(reader: reader)
    selectionTools.pronunciationAllowed = { [weak speech, weak recorded] in
      speech?.isActive == false && recorded?.isActive == false
    }
    _selectionTools = State(initialValue: selectionTools)
  }

  var body: some View {
    readerLifecycle
      .sheet(item: $positionReset) { reset in
        NativePositionResetView(model: reset, closed: positionResetClosed)
      }
      .sheet(isPresented: $showingHelp) {
        EPUBReaderHelpView(
          flow: model.isContinuous ? "scrolled" : "paginated",
          animation: model.preferences.value.pageAnimation,
          rightToLeft: model.rightToLeft, speechActive: speech.isActive)
      }
      .sheet(isPresented: $bridge.isPresented, onDismiss: bridge.cancel) {
        NativeContinuationView(model: bridge)
      }
      .sheet(isPresented: $showingPosition) {
        EPUBPositionNavigationView(reader: model, onJump: jumpToPosition)
      }
      .sheet(item: $selectionTools.presentation, onDismiss: selectionTools.dismiss) { _ in
        EPUBSelectionToolsView(model: selectionTools)
      }
      .sheet(isPresented: $showingSpeech) {
        NavigationStack {
          ScrollView { NativeTTSControlsView(model: speech) }
            .navigationTitle("System speech")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
              ToolbarItem(placement: .confirmationAction) {
                Button("Done", action: closeSpeech)
                  .disabled(speech.isPositionResetting && !speech.positionResetRecovery)
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
                Button("Done", action: closeRecorded).accessibilityIdentifier(
                  "recordedCloseControls")
              }
            }
        }
      }
      .fullScreenCover(isPresented: $showingContents) {
        EPUBContentsView(
          model: model, outline: outline, isPinned: chrome.contentsPinned,
          togglePin: toggleContentsPin, jump: jumpToContentsEntry)
      }
      .fullScreenCover(isPresented: $showingSearch) {
        EPUBSearchView(model: model, initialQuery: initialSearchQuery)
      }
      .fullScreenCover(isPresented: $showingSettings, onDismiss: applySettings) {
        EPUBPreferencesView(model: model.preferences)
      }
      .fullScreenCover(isPresented: $showingBookmarks) {
        if let cfi = model.selectionCFI ?? model.visibleLocation?.cfi {
          EPUBBookmarksView(
            reader: model, cfi: cfi,
            defaultTitle: model.selectionText.isEmpty
              ? "Chapter \((model.visibleLocation?.chapterIndex ?? 0) + 1)"
              : String(model.selectionText.prefix(200)),
            onJump: jumpToBookmark)
        }
      }
      .interactiveDismissDisabled(
        !canCloseReader || model.hasPendingSave || model.position.conflict.isBlocked
          || speech.isActive || speech.position.hasPendingSave
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

  private var readerLifecycle: some View {
    readerNavigation
      .task { await loadReader() }
      .onChange(of: model.location?.cfi) { old, new in
        if old != nil && new != old && !showingContents && !showingSearch && !showingSettings
          && !showingBookmarks && !showingPosition && !showingHelp
          && model.error == nil && !model.position.conflict.isBlocked
        {
          hidesControlsAfterNavigation = true
          finishChromeNavigation()
        }
      }
      .onChange(of: isReaderAction) { _, _ in finishChromeNavigation() }
      .onChange(of: model.isNavigating) { _, _ in finishChromeNavigation() }
      .onChange(of: model.isSaving) { _, _ in finishChromeNavigation() }
      .onChange(of: controlsVisible) { _, visible in restoreControlsFocused = !visible }
      .onChange(of: model.position.conflict.isBlocked) { _, blocked in
        if blocked { showControls() }
      }
      .onChange(of: model.error) { _, error in if error != nil { showControls() } }
      .onChange(of: reduceMotion) { _, value in model.setReduceMotion(value) }
      .onChange(of: dynamicTypeSize) { _, _ in applySettings() }
      .onChange(of: model.publicationID) { _, _ in selectionTools.detach() }
      .onChange(of: model.isReady) { _, ready in
        if ready { rebuildContents() } else { selectionTools.detach() }
      }
      .onChange(of: scenePhase) { _, phase in
        if phase == .active {
          Task {
            await model.refreshPosition()
            await speech.foreground()
            await recorded.foreground()
          }
        }
        if phase == .background {
          selectionTools.dismiss()
          bridge.cancel()
          speech.background()
          Task { _ = await recorded.stopAndSave() }
        }
      }
      .onDisappear(perform: closeReaderIfAllowed)
  }

  private var readerNavigation: some View {
    NavigationStack {
      GeometryReader { geometry in
        VStack(spacing: 0) {
          if chrome.contentsPinned && geometry.size.width < 900 {
            pinnedContents.frame(height: min(240, geometry.size.height * 0.28))
            Divider()
          }
          HStack(spacing: 0) {
            if chrome.contentsPinned && geometry.size.width >= 900 {
              pinnedContents.frame(width: min(320, geometry.size.width * 0.32))
              Divider()
            }
            publication
          }
        }
        .safeAreaInset(edge: .bottom) {
          ScrollView {
            readerFooter
              .fixedSize(horizontal: false, vertical: true)
              .onGeometryChange(for: CGFloat.self) { geometry in
                geometry.size.height
              } action: { height in
                footerContentHeight = height
              }
          }
          .frame(height: min(footerContentHeight, geometry.size.height * 0.45))
          .scrollBounceBehavior(.basedOnSize)
          .background(.background)
        }
      }
      .navigationTitle("Ebook reader")
      .navigationBarTitleDisplayMode(.inline)
      .toolbarVisibility(controlsVisible ? .visible : .hidden, for: .navigationBar)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("Close reader", action: closeReader).disabled(!canCloseReader)
            .accessibilityIdentifier("epubCloseReader")
        }
        ToolbarItem(placement: .topBarTrailing) {
          Menu("Reader display", systemImage: "rectangle.topthird.inset.filled") {
            Button(
              chrome.controlsPinned ? "Unpin reader controls" : "Pin reader controls",
              action: toggleControlsPin
            ).disabled(!canChangeReaderLayout)
              .accessibilityIdentifier("epubPinReaderControls")
            Button("Hide reader controls", action: hideControls)
              .disabled(!canChangeReaderLayout)
              .accessibilityIdentifier("epubHideReaderControls")
            Button(
              chrome.contentsPinned ? "Unpin Contents" : "Pin Contents", action: toggleContentsPin
            ).disabled(!model.isReady || !canChangeReaderLayout)
              .accessibilityIdentifier("epubTogglePinnedContents")
            Button("Reader help", action: openHelp).accessibilityIdentifier("epubHelp")
          }
          .accessibilityIdentifier("epubReaderDisplay")
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button("Text to speech", systemImage: "speaker.wave.2", action: openSpeech)
            .disabled(!model.isReady || isReaderAction || bridge.isPresented || speech.isClosing)
            .accessibilityIdentifier("epubTextToSpeech")
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button(
            "Clear reading position", systemImage: "arrow.counterclockwise",
            action: promptPositionReset
          )
          .disabled(!model.isReady || isReaderAction || bridge.isPresented)
          .accessibilityIdentifier("epubClearReadingPosition")
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
      .accessibilityAction(.escape, showControls)
    }
  }

  private var controlsVisible: Bool {
    chrome.controlsVisible || !model.isReady || model.position.conflict.isBlocked
  }

  private var publication: some View {
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
  }

  private var pinnedContents: some View {
    EPUBPinnedContentsView(
      outline: outline, canNavigate: model.canNavigate && !isReaderAction && !bridge.isPresented,
      canChangeLayout: canChangeReaderLayout,
      open: openPinnedContentsEntry, unpin: toggleContentsPin, browse: openContents)
  }

  private var canChangeReaderLayout: Bool {
    !isReaderAction && positionReset == nil && !model.isPositionResetting
      && !model.isNavigating && !model.isSaving && !model.isSearching && !bridge.isPresented
  }

  private var readerFooter: some View {
    VStack(spacing: 8) {
      if !controlsVisible {
        ViewThatFits(in: .horizontal) {
          HStack { restoreControls }
          VStack { restoreControls }
        }
      }
      if speech.isActive || speech.position.message != nil {
        speechStatus
      }
      if recorded.isActive || recorded.position.message != nil {
        ViewThatFits(in: .horizontal) {
          HStack { recordedStatus }
          VStack { recordedStatus }
        }
      }
      if controlsVisible && model.location != nil {
        Text(model.positionText)
          .font(.caption).accessibilityIdentifier("epubReadingPosition")
      }
      // Save feedback must not resize the publication and trigger another relocation/save.
      ReaderPositionChoiceView(
        conflict: model.position.conflict,
        isSaving: model.position.isSaving || model.position.isResolving,
        chooseLocal: chooseLocalPosition, chooseRemote: chooseRemotePosition)
      readerFeedback
      if model.selectionCFI != nil {
        ViewThatFits(in: .horizontal) {
          HStack { selectionActions }
          VStack { selectionActions }
        }
      }
      if controlsVisible {
        ViewThatFits(in: .horizontal) {
          HStack { navigationButtons }
          VStack { navigationButtons }
        }
      }
    }
    .buttonStyle(.plain).padding(.horizontal).padding(.vertical, 8).background(.background)
  }

  @ViewBuilder private var restoreControls: some View {
    Button("Show reader controls", action: showControls).frame(minHeight: 44)
      .keyboardShortcut(.escape, modifiers: [])
      .accessibilityFocused($restoreControlsFocused)
      .accessibilityIdentifier("epubShowReaderControls")
    Button("Close reader", action: closeReader).frame(minHeight: 44).disabled(!canCloseReader)
      .accessibilityIdentifier("epubHiddenCloseReader")
    Button("Reader help", action: openHelp).frame(minHeight: 44)
      .accessibilityIdentifier("epubHiddenHelp")
  }

  private var canCloseReader: Bool {
    model.canClose && positionReset == nil
      && (!speech.isPositionResetting || speech.positionResetRecovery) && !isReaderAction
      && !bridge.isPresented && !speech.isClosing
      && !speech.isStopping
      && !speech.preferences.isSaving && !speech.position.isSaving
      && !recorded.isBusy && !recorded.position.isSaving
  }

  private var selectionActions: some View {
    Group {
      Button("Bookmark selected passage", action: openBookmarks).frame(minHeight: 44)
        .accessibilityIdentifier("epubBookmarkSelection")
        .disabled(!model.canNavigate || isReaderAction || bridge.isPresented)
      Menu("Selected passage", systemImage: "text.cursor") {
        Button("Define selected text", action: defineSelection)
          .accessibilityIdentifier("epubDefineSelection")
        Button("Translate selected text", action: translateSelection)
          .accessibilityIdentifier("epubTranslateSelection")
        Button("Search selected text", action: searchSelection)
          .accessibilityIdentifier("epubSearchSelection")
      }
      .frame(minHeight: 44)
      .disabled(!model.canNavigate || isReaderAction || bridge.isPresented)
      .accessibilityIdentifier("epubSelectionTools")
    }
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
        if let contentsMessage {
          Text(contentsMessage).font(.caption).fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("epubContentsNavigationMessage")
        }
        if let message = chrome.message {
          Text(message).font(.caption).fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("epubChromePreferenceMessage")
        }
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

  private func loadReader() async {
    await chrome.load()
    model.setReduceMotion(reduceMotion)
    await model.load()
    rebuildContents()
    if model.isReady {
      await recorded.open()
      await speech.open()
    }
  }

  private func closeReaderIfAllowed() {
    if !showingContents && !showingSearch && !showingSettings && !showingBookmarks
      && !showingSpeech && !showingRecorded && !showingPosition && !showingHelp
      && !bridge.isPresented && selectionTools.presentation == nil && positionReset == nil
    {
      chrome.close()
      Task {
        bridge.cancel()
        _ = await recorded.stopAndSave()
        recorded.close()
        speech.close()
        model.close()
      }
    }
  }

  private func promptPositionReset() {
    guard model.isReady, !isReaderAction, !bridge.isPresented else { return }
    isReaderAction = true
    positionReset = NativePositionResetModel(
      api: model.api,
      target: .file(
        bookID: model.bookID, fileID: model.file.id, label: model.file.filename ?? "Ebook"),
      prepare: {
        try await model.beginPositionReset()
        try await speech.beginPositionReset()
        try await recorded.beginPositionReset()
      },
      acknowledged: {
        model.acknowledgePositionReset()
        recorded.acknowledgePositionReset()
      })
  }

  private func positionResetClosed(_ reset: NativePositionResetModel) {
    reset.detach()
    positionReset = nil
    if reset.didAttempt {
      bridge.cancel()
      recorded.close()
      speech.close()
      model.close()
      dismiss()
    } else {
      model.cancelPositionReset()
      recorded.cancelPositionReset()
      speech.cancelPositionReset()
      isReaderAction = false
    }
  }

  private func rebuildContents() {
    outline.rebuild(contents: model.contents, chapterCount: model.chapterCount)
  }

  private func hideControls() {
    guard canChangeReaderLayout else { return }
    chrome.hideControls()
    restoreControlsFocused = true
  }

  private func showControls() {
    hidesControlsAfterNavigation = false
    chrome.showControls()
    restoreControlsFocused = false
  }

  private func finishChromeNavigation() {
    guard hidesControlsAfterNavigation, canChangeReaderLayout else { return }
    hidesControlsAfterNavigation = false
    if model.error == nil && !model.position.conflict.isBlocked && !model.hasPendingSave {
      chrome.didNavigate()
    }
  }

  private func toggleControlsPin() {
    guard canChangeReaderLayout else { return }
    Task { await chrome.toggleControlsPin() }
  }
  private func toggleContentsPin() {
    guard canChangeReaderLayout else { return }
    Task { await chrome.toggleContentsPin() }
  }
  private func openHelp() { showingHelp = true }

  private func openPinnedContentsEntry(_ entry: EPUBContentsEntry) {
    Task { _ = await jumpToContentsEntry(entry) }
  }

  private func jumpToContentsEntry(_ entry: EPUBContentsEntry) async -> Bool {
    guard model.canNavigate, !isReaderAction, positionReset == nil, !bridge.isPresented,
      !speech.isClosing, !speech.isStopping, !speech.preferences.isSaving, !Task.isCancelled
    else { return false }
    contentsMessage = nil
    isReaderAction = true
    defer { isReaderAction = false }
    guard await recorded.stopAndSave(), await speech.stopAndSave(), model.canNavigate else {
      return false
    }
    let moved: Bool
    if let href = entry.href {
      moved = await model.goToHref(href)
    } else if let chapter = entry.chapter {
      moved = await model.goToContentsChapter(chapter)
    } else {
      return false
    }
    guard moved else {
      contentsMessage =
        "This Contents passage could not be opened. Review the reader status before retrying."
      showControls()
      return false
    }
    let saved = await model.saveProgress()
    if !saved {
      contentsMessage =
        "The passage is open, but its save was not confirmed. Review the resume choice or retry Save position."
      showControls()
    }
    return saved && model.isReady && !model.position.conflict.isBlocked && !Task.isCancelled
  }

  private func previousPage() { navigate { await model.turn(forward: false) } }
  private func nextPage() { navigate { await model.turn(forward: true) } }
  private func previousSection() {
    guard model.canGoToPreviousSection, let index = model.visibleLocation?.chapterIndex else {
      return
    }
    navigate { await model.goToChapter(index - 1) }
  }
  private func nextSection() {
    guard model.canGoToNextSection, let index = model.visibleLocation?.chapterIndex else { return }
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
  private func jumpToBookmark(_ cfi: String) async -> EPUBPositionJumpResult {
    guard model.canNavigate, !isReaderAction, !bridge.isPresented,
      !speech.isClosing, !speech.isStopping, !speech.preferences.isSaving
    else { return .failed }
    isReaderAction = true
    defer { isReaderAction = false }
    guard await recorded.stopAndSave(), await speech.stopAndSave() else { return .failed }
    return await model.goToBookmarkCFI(cfi)
  }
  private func savePosition() {
    Task {
      model.adoptVisiblePosition()
      await model.saveProgress()
    }
  }
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
  private func openSearch() {
    initialSearchQuery = ""
    navigate { showingSearch = true }
  }
  private func defineSelection() {
    guard let passage = model.selectedPassage(language: language) else { return }
    selectionTools.open(.dictionary, passage: passage)
  }
  private func translateSelection() {
    guard let passage = model.selectedPassage(language: language) else { return }
    selectionTools.open(.translation, passage: passage)
  }
  private func searchSelection() {
    guard let passage = model.selectedPassage(language: language) else { return }
    initialSearchQuery = passage.text
    navigate { showingSearch = true }
  }
  private func openSettings() { navigate { showingSettings = true } }
  private func openBookmarks() { navigate { showingBookmarks = true } }
  private func applySettings() { navigate { await model.applyPreferences() } }
  private func openContinuation() { Task { await bridge.open() } }
  private func openSpeech() {
    Task {
      if speech.position.conflict.isBlocked {
        await recorded.freezeForPositionChoice()
        showingSpeech = true
      } else if await recorded.stopAndSave() {
        showingSpeech = true
      }
    }
  }
  private func openRecorded() {
    Task {
      if recorded.position.conflict.isBlocked {
        await speech.stop()
        showingRecorded = true
      } else if await speech.stopAndSave() {
        showingRecorded = true
      }
    }
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
  private func chooseLocalPosition() { choosePosition(local: true) }
  private func chooseRemotePosition() { choosePosition(local: false) }
  private func choosePosition(local: Bool) {
    Task {
      guard !isReaderAction else { return }
      isReaderAction = true
      defer { isReaderAction = false }
      await speech.stop()
      await recorded.freezeForPositionChoice()
      await model.choosePosition(local: local)
    }
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
