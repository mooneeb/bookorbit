import SwiftUI

struct PDFReaderView: View {
  let api: BookOrbitAPI
  let bookID: Int
  let fileID: Int
  @State private var model: PDFReaderModel
  @State private var ink: PDFSourceInkEditor
  @State private var passageRepair: PDFPassageRepairModel?
  let annotation: NativeAnnotationItem?
  let repairAnnotation: NativeAnnotationItem?
  let onRepairSelection: ((NativeAnnotationPayload) -> Void)?
  @State private var preferences: ReaderPreferencesModel
  @State private var positionReset: NativePositionResetModel?
  @State private var confirmsDiscard = false
  @State private var isNavigating = false
  @State private var isSearching = false
  @State private var isBrowsingContents = false
  @State private var isBrowsingThumbnails = false
  @State private var isEditingPreferences = false
  @State private var isBrowsingBookmarks = false
  @State private var isTurning = false
  @State private var pageLayout = FixedPageLayout(pageCount: 0, facing: false, singlePrefix: 0)
  @ScaledMetric(relativeTo: .body) private var actionWidth = 150.0
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.dismiss) private var dismiss

  init(
    api: BookOrbitAPI, bookID: Int, file: BookDetailFile,
    annotation: NativeAnnotationItem? = nil, repairAnnotation: NativeAnnotationItem? = nil,
    onRepairSelection: ((NativeAnnotationPayload) -> Void)? = nil
  ) {
    self.api = api
    self.bookID = bookID
    fileID = file.id
    self.annotation = annotation
    self.repairAnnotation = repairAnnotation
    self.onRepairSelection = onRepairSelection
    _model = State(initialValue: PDFReaderModel(api: api, file: file))
    _ink = State(initialValue: PDFSourceInkEditor(api: api, bookID: bookID, fileID: file.id))
    _passageRepair = State(
      initialValue: repairAnnotation.flatMap {
        $0.kind == "pdf_ink" ? nil : PDFPassageRepairModel(original: $0)
      })
    _preferences = State(
      initialValue: ReaderPreferencesModel(api: api, fileID: file.id, group: "pdf"))
  }

  var body: some View {
    NavigationStack {
      Group {
        if model.requiresPassword {
          PDFPasswordView(model: model, cancel: cancelOpening)
        } else {
          readerBody
        }
      }
      .navigationTitle("PDF reader")
      .navigationBarTitleDisplayMode(.inline)
    }
    .task {
      await model.load()
      if let page = annotation?.pdf?.page ?? annotation?.pageno.map({ $0 - 1 }),
        let document = model.document,
        (0..<document.pageCount).contains(page)
      {
        model.reveal(page: page)
      }
      ink.currentPage = model.pageIndex
      ink.loadedSourceRevision = model.sourceRevision
      await ink.load()
      if let document = model.document { passageRepair?.bind(document: document, source: ink) }
      await ink.preparePages(Set(pageLayout.pages(in: pageLayout.unit(for: model.pageIndex))))
      if let annotation, annotation.kind == "pdf_ink" { ink.select(annotation) }
    }
    .task(id: "\(model.pageIndex)|\(pageLayout.facing)|\(pageLayout.pageCount)") {
      await ink.openPage(model.pageIndex)
      await ink.preparePages(Set(pageLayout.pages(in: pageLayout.unit(for: model.pageIndex))))
    }
    .onChange(of: model.pageIndex) { _, _ in passageRepair?.changedPage() }
    .task(id: ink.repositoryGeneration) { await ink.refreshItems() }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active { Task { await model.refreshPosition() } }
    }
    .task { await preferences.load() }
    .onDisappear {
      if !isNavigating && !isSearching && !isBrowsingContents && !isEditingPreferences
        && !isBrowsingBookmarks && !isBrowsingThumbnails && positionReset == nil
      {
        model.close()
        ink.close()
        preferences.close()
      }
    }
    .sheet(item: $positionReset) { reset in
      NativePositionResetView(model: reset, closed: positionResetClosed)
    }
    .interactiveDismissDisabled(positionReset != nil)
    .fullScreenCover(isPresented: $isBrowsingBookmarks) {
      if let document = model.document {
        ReaderBookmarksView(
          api: api, bookID: bookID, fileID: fileID, currentPage: model.pageIndex + 1,
          pageCount: document.pageCount, onSelect: model.didTurn)
      }
    }
    .fullScreenCover(isPresented: $isEditingPreferences) {
      ReaderPreferencesView(model: preferences)
    }
    .fullScreenCover(isPresented: $isBrowsingContents) {
      if let document = model.document {
        PDFContentsView(document: document, onSelect: model.openContentsPage)
      }
    }
    .fullScreenCover(isPresented: $isBrowsingThumbnails) {
      PDFThumbnailsView(model: model, rotation: preferences.value.pdf.rotation)
    }
    .fullScreenCover(isPresented: $isSearching) {
      if let document = model.document {
        PDFSearchView(document: document, onSelect: model.openSearchMatch)
      }
    }
    .fullScreenCover(isPresented: $isNavigating) {
      if let document = model.document {
        ReaderPageNavigationView(
          currentPage: model.pageIndex + 1, pageCount: document.pageCount, onNavigate: model.didTurn
        )
      }
    }
    .alert("Discard unsaved position?", isPresented: $confirmsDiscard) {
      Button("Keep reading", role: .cancel) {}
      Button("Discard and close", role: .destructive, action: dismiss.callAsFunction)
    } message: {
      Text(
        "Your latest page turn has not been saved. The next session will resume at the last saved position."
      )
    }
  }

  private var readerBody: some View {
    VStack(spacing: 0) {
      if let document = model.document {
        if let passageRepair {
          PDFPassageRepairControls(model: passageRepair, confirm: confirmPassageRepair)
        } else {
          PDFSourceInkControls(editor: ink)
        }
        if repairAnnotation?.kind == "pdf_ink" {
          Button("Attach ink to this page", action: repairHere)
            .frame(minHeight: 44)
            .disabled(!ink.canEdit || ink.isSaving)
            .accessibilityIdentifier("pdfRepairHere")
        }
        PDFCurlView(
          document: document, pageIndex: model.pageIndex, selection: model.searchSelection,
          onTurn: model.didTurn, settings: preferences.value.pdf,
          animation: preferences.value.pageAnimation, onLayout: { pageLayout = $0 },
          onTransition: { isTurning = $0 }, inkEditor: ink, passageRepair: passageRepair
        )
        .onAppear { passageRepair?.bind(document: document, source: ink) }
        .allowsHitTesting(!model.isClosing && !model.position.conflict.isBlocked)
      } else if model.error == nil {
        ProgressView("Opening PDF…")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      if let error = model.error {
        Text(error).font(.body).foregroundStyle(.primary)
          .fixedSize(horizontal: false, vertical: true)
          .padding().accessibilityIdentifier("pdfReaderError")
      }
      VStack {
        if let document = model.document {
          Text("Page \(model.pageIndex + 1) of \(document.pageCount)")
        }
        ReaderPositionChoiceView(
          conflict: model.position.conflict,
          isSaving: model.position.isSaving || model.position.isResolving,
          chooseLocal: chooseLocalPosition, chooseRemote: chooseRemotePosition)
        if !model.status.isEmpty { Text(model.status) }
        if model.hasUnsavedPosition {
          Button("Retry saving", action: model.retrySaving)
            .disabled(model.position.conflict.isBlocked || model.position.isResolving)
            .buttonStyle(.plain)
            .frame(minHeight: 44)
          Button("Close without saving") { confirmsDiscard = true }
            .buttonStyle(.plain)
            .frame(minHeight: 44)
        }
        if model.document != nil {
          readerActions
        } else {
          Button("Cancel", action: cancelOpening)
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .frame(minWidth: 44, minHeight: 44)
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("pdfCancelOpening")
        }
      }
      .font(.body)
      .foregroundStyle(.primary)
      .padding()
    }
  }

  private var readerActions: some View {
    LazyVGrid(columns: [GridItem(.adaptive(minimum: actionWidth))]) {
      Button("Previous page", action: previousPage)
        .frame(minHeight: 44)
        .keyboardShortcut(.leftArrow, modifiers: [])
        .accessibilityIdentifier("pdfPreviousPage")
        .disabled(
          model.document == nil
            || pageLayout.adjacentPage(to: model.pageIndex, delta: -1) == nil
            || model.isClosing || isTurning || passageRepair?.locksPage == true)
      Button("Next page", action: nextPage)
        .frame(minHeight: 44)
        .keyboardShortcut(.rightArrow, modifiers: [])
        .accessibilityIdentifier("pdfNextPage")
        .disabled(
          model.document == nil
            || pageLayout.adjacentPage(to: model.pageIndex, delta: 1) == nil
            || model.isClosing || isTurning || passageRepair?.locksPage == true)
      Button("Go to page") { isNavigating = true }
        .frame(minHeight: 44)
        .accessibilityIdentifier("pdfNavigate")
        .disabled(model.document == nil || model.isClosing)
      Button("Contents") { isBrowsingContents = true }
        .frame(minHeight: 44)
        .accessibilityIdentifier("pdfContents")
        .disabled(model.document == nil || model.isClosing)
      Button("Thumbnails", action: browseThumbnails)
        .frame(minHeight: 44)
        .accessibilityIdentifier("pdfThumbnails")
        .disabled(model.document == nil || model.isClosing || isTurning)
      Button("Search") { isSearching = true }
        .frame(minHeight: 44)
        .accessibilityIdentifier("pdfSearch")
        .disabled(model.document == nil || model.isClosing)
      Button("Reader settings") { isEditingPreferences = true }
        .frame(minHeight: 44)
        .accessibilityIdentifier("readerSettings")
        .disabled(model.isClosing || preferences.isLoading)
      Button {
        isBrowsingBookmarks = true
      } label: {
        Text("Bookmarks").frame(maxWidth: .infinity, minHeight: 44)
          .contentShape(Rectangle())
      }
      .accessibilityIdentifier("readerBookmarks")
      .disabled(model.document == nil || model.isClosing || isTurning)
      Button("Clear reading position", action: promptPositionReset)
        .frame(minHeight: 44)
        .disabled(model.isClosing || isTurning || positionReset != nil)
        .accessibilityIdentifier("pdfClearReadingPosition")
      Button("Close reader", action: closeReader)
        .frame(minHeight: 44)
        .accessibilityIdentifier("pdfCloseReader")
        .disabled(model.isClosing)
    }
    .buttonStyle(.plain)
    .frame(minHeight: 44)
  }

  private func cancelOpening() {
    ink.close()
    model.close()
    preferences.close()
    dismiss()
  }
  private func promptPositionReset() {
    guard !model.isClosing, !isTurning, positionReset == nil else { return }
    positionReset = NativePositionResetModel(
      api: api,
      target: .file(bookID: bookID, fileID: fileID, label: model.file.filename ?? "Book file"),
      prepare: model.beginPositionReset, acknowledged: { model.acknowledgePositionReset() })
  }

  private func positionResetClosed(_ reset: NativePositionResetModel) {
    reset.detach()
    positionReset = nil
    if reset.didAttempt {
      model.close()
      preferences.close()
      dismiss()
    } else {
      model.cancelPositionReset()
    }
  }

  private func browseThumbnails() { isBrowsingThumbnails = true }
  private func chooseLocalPosition() { Task { await model.choosePosition(local: true) } }
  private func chooseRemotePosition() { Task { await model.choosePosition(local: false) } }

  private func closeReader() {
    guard model.document != nil else {
      cancelOpening()
      return
    }
    Task {
      if await model.prepareToClose() { dismiss() }
    }
  }
  private func repairHere() {
    guard let repairAnnotation,
      let payload = ink.repairPayload(repairAnnotation, page: model.pageIndex)
    else { return }
    onRepairSelection?(payload)
    dismiss()
  }
  private func confirmPassageRepair() {
    guard let passageRepair, onRepairSelection != nil else { return }
    Task {
      guard let payload = await passageRepair.confirmedPayload() else { return }
      onRepairSelection?(payload)
      dismiss()
    }
  }
  private func previousPage() {
    if let page = pageLayout.adjacentPage(to: model.pageIndex, delta: -1) {
      model.didTurn(to: page)
    }
  }
  private func nextPage() {
    if let page = pageLayout.adjacentPage(to: model.pageIndex, delta: 1) { model.didTurn(to: page) }
  }
}
