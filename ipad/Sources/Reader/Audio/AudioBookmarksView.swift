import SwiftUI

struct AudioBookmarksView: View {
  let player: AudioPlayerModel
  @Environment(\.dismiss) private var dismiss
  @State private var model: AudioBookmarksModel
  @State private var removing: AudiobookBookmark?
  @State private var showingRemoval = false
  @State private var showingUnconfirmedClose = false
  @State private var showingDiscard = false
  @State private var isJumping = false

  init(player: AudioPlayerModel) {
    self.player = player
    _model = State(
      initialValue: AudioBookmarksModel(
        api: player.engine.api, bookID: player.engine.bookID,
        capture: { [weak player] in player?.bookmarkPosition }))
  }

  var body: some View {
    NavigationStack {
      Form {
        Section(model.editingID == nil ? "New bookmark" : "Edit bookmark") {
          if model.editingID == nil {
            if let point = model.currentPosition {
              LabeledContent(
                "Current position",
                value: AudioPlaybackModel.clock(Double(point.milliseconds) / 1000)
              )
              .accessibilityIdentifier("audioBookmarkPosition")
            } else {
              Text("Bookmark positions are unavailable until all track durations are known.")
            }
          }
          TextField("Title", text: $model.title, axis: .vertical)
            .disabled(model.hasPendingWrite || model.isBusy || isJumping)
            .accessibilityIdentifier("audioBookmarkTitle")
          TextField("Note", text: $model.note, axis: .vertical)
            .disabled(model.hasPendingWrite || model.isBusy || isJumping)
            .lineLimit(3...12).accessibilityIdentifier("audioBookmarkNote")
          Text(
            "Title: \(model.title.unicodeScalars.count)/500. Note: \(model.note.unicodeScalars.count)/4000."
          )
          .font(.caption).fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("audioBookmarkLimits")
          Button {
            Task { await model.save() }
          } label: {
            Text(model.isSaving ? "Saving…" : "Save bookmark").font(.body).frame(minHeight: 44)
          }
          .disabled(!model.canSave || isJumping).accessibilityIdentifier("audioBookmarkSave")
          if model.editingID != nil {
            Button("New bookmark", action: model.newBookmark)
              .frame(minHeight: 44).disabled(model.isBusy || model.hasPendingWrite || isJumping)
              .accessibilityIdentifier("audioBookmarkNew")
          }
        }
        .disabled(model.isSaving || isJumping)
        if let status = model.status {
          Section { Text(status).accessibilityIdentifier("audioBookmarkStatus") }
        }
        if let error = model.error {
          Section {
            Text(error).fixedSize(horizontal: false, vertical: true)
              .accessibilityIdentifier("audioBookmarkError")
            if model.hasPendingWrite {
              Button("Discard unconfirmed draft") { showingDiscard = true }
                .frame(minHeight: 44).disabled(model.isBusy || isJumping)
                .accessibilityIdentifier("audioBookmarkDiscard")
            } else {
              Button("Reload bookmarks") { Task { await model.firstPage() } }
                .frame(minHeight: 44).disabled(model.isBusy || isJumping)
                .accessibilityIdentifier("audioBookmarkReload")
            }
          }
        }
        Section("Bookmarks") {
          if model.isLoading { ProgressView("Loading bookmarks…") }
          if model.hasLoaded, model.items.isEmpty { Text("No bookmarks on this page.") }
          ForEach(model.items) { item in
            VStack(alignment: .leading, spacing: 8) {
              Text(item.title).font(.headline).fixedSize(horizontal: false, vertical: true)
              Text(AudioPlaybackModel.clock(Double(item.positionMs) / 1000)).monospacedDigit()
              if let note = item.note { Text(note).fixedSize(horizontal: false, vertical: true) }
              ViewThatFits(in: .horizontal) {
                HStack { actions(item) }
                VStack(alignment: .leading) { actions(item) }
              }
            }
            .accessibilityIdentifier("audioBookmarkRow\(item.id)")
          }
          HStack {
            Button("First page") { Task { await model.firstPage() } }
              .frame(minHeight: 44).disabled(model.isBusy || model.hasPendingWrite || isJumping)
              .accessibilityIdentifier("audioBookmarkFirstPage")
            Spacer()
            Text("Page \(model.pageNumber)")
          }
          ViewThatFits(in: .horizontal) {
            HStack { pagingButtons }
            VStack(alignment: .leading) { pagingButtons }
          }
        }
      }
      .navigationTitle("Audio bookmarks")
      .safeAreaInset(edge: .bottom) {
        HStack {
          Spacer()
          Button(action: finish) {
            Text("Done").font(.body).fixedSize(horizontal: false, vertical: true)
              .padding(.horizontal, 16).frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
          }
          .disabled(model.isBusy || isJumping).accessibilityIdentifier("audioBookmarksDone")
        }
        .buttonStyle(.plain).foregroundStyle(Color(uiColor: .label))
        .padding(.horizontal).background(Color(uiColor: .systemBackground))
      }
    }
    .task { await model.load() }
    .onDisappear(perform: model.close)
    .interactiveDismissDisabled(model.isBusy || model.hasPendingWrite || isJumping)
    .confirmationDialog(
      "Remove this bookmark?", isPresented: $showingRemoval, titleVisibility: .visible,
      presenting: removing
    ) { item in
      Button("Remove bookmark", role: .destructive) {
        removing = nil
        Task { await model.remove(item) }
      }
    }
    .alert("Bookmark change not confirmed", isPresented: $showingUnconfirmedClose) {
      Button("Keep bookmarks open", role: .cancel) {}
      Button("Close without confirmation", role: .destructive) { dismiss() }
    } message: {
      Text(
        "The server may already have saved the change. Reopen bookmarks to check before trying again."
      )
    }
    .alert("Discard this unconfirmed draft?", isPresented: $showingDiscard) {
      Button("Keep draft", role: .cancel) {}
      Button("Discard draft", role: .destructive) {
        Task { await model.discardPending() }
      }
    } message: {
      Text(
        "The server may already have saved the change. Bookmarks will reload before you add another."
      )
    }
  }

  @ViewBuilder
  private func actions(_ item: AudiobookBookmark) -> some View {
    Button {
      isJumping = true
      Task {
        if await player.jumpToBookmark(positionMs: item.positionMs) { dismiss() }
        isJumping = false
      }
    } label: {
      Text("Go to bookmark").font(.body).frame(minHeight: 44)
    }
    .disabled(model.isBusy || model.hasPendingWrite || isJumping || !player.canInteract)
    .accessibilityIdentifier("audioBookmarkJump\(item.id)")
    Button("Edit") { model.beginEditing(item) }
      .frame(minHeight: 44).disabled(model.isBusy || model.hasPendingWrite || isJumping)
      .accessibilityIdentifier("audioBookmarkEdit\(item.id)")
    Button("Remove") {
      removing = item
      showingRemoval = true
    }
    .frame(minHeight: 44)
    .disabled(model.isBusy || isJumping || !model.canRemove(item))
    .accessibilityIdentifier("audioBookmarkRemove\(item.id)")
  }

  @ViewBuilder
  private var pagingButtons: some View {
    Button("Previous") { Task { await model.previousPage() } }
      .frame(minHeight: 44)
      .disabled(model.isBusy || model.hasPendingWrite || !model.hasPrevious || isJumping)
      .accessibilityIdentifier("audioBookmarkPreviousPage")
    Button("Next") { Task { await model.nextPage() } }
      .frame(minHeight: 44)
      .disabled(model.isBusy || model.hasPendingWrite || model.nextCursor == nil || isJumping)
      .accessibilityIdentifier("audioBookmarkNextPage")
  }

  private func finish() {
    if model.canClose { dismiss() } else { showingUnconfirmedClose = true }
  }
}
