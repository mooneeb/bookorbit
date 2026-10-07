import PhotosUI
import SwiftUI

struct CoverEditorView: View {
  @State private var model: CoverEditorModel
  @Environment(\.dismiss) private var dismiss

  init(api: BookOrbitAPI, book: BookDetail) {
    _model = State(initialValue: CoverEditorModel(api: api, book: book))
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("Edit covers").font(.headline).accessibilityAddTraits(.isHeader)
        Spacer()
        Button("Done", action: dismiss.callAsFunction).disabled(model.isBusy)
          .frame(minHeight: 44)
          .accessibilityIdentifier("closeCoverEditor")
      }.padding(.horizontal)
      ScrollView {
        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 280), alignment: .top)], alignment: .center,
          spacing: 24
        ) {
          ForEach(model.media) { medium in CoverEditorTile(model: model, medium: medium) }
        }.padding()
      }
      .scrollEdgeEffectHidden()
      .clipped()
      if model.isSaving { ProgressView("Saving cover…").padding() }
      if model.isReloading { ProgressView("Reloading covers…").padding() }
      if let medium = model.reExtracting {
        ProgressView("Re-extracting \(medium.rawValue) cover…").padding()
          .accessibilityIdentifier("reExtractingCover")
      }
      if let message = model.message {
        Text(message).fixedSize(horizontal: false, vertical: true).padding()
          .accessibilityIdentifier("coverResult")
      }
    }
    .buttonStyle(CoverActionButtonStyle())
    .foregroundStyle(.primary)
    .background(.background)
    .interactiveDismissDisabled(model.isBusy)
    .task { await model.load() }
    .onDisappear(perform: model.close)
  }
}

private struct CoverActionButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(Color(uiColor: .label))
      .contentShape(Rectangle())
      .opacity(configuration.isPressed ? 0.7 : 1)
  }
}

private struct CoverEditorTile: View {
  @Bindable var model: CoverEditorModel
  let medium: CoverMedium
  @State private var selection: PhotosPickerItem?
  @State private var isConfirmingRevert = false
  @State private var isFindingCover = false

  private var preview: UIImage? {
    model.pending[medium].flatMap { UIImage(data: $0.preview) } ?? model.images[medium]
  }

  private var extractionLabel: String {
    model.failedReExtractions.contains(medium)
      ? "Retry \(medium.rawValue) cover extraction" : "Re-extract \(medium.rawValue) cover"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(medium.label).font(.title2).accessibilityAddTraits(.isHeader)
      if let url = model.pendingURLs[medium] {
        RemoteCoverPreview(api: model.api, url: url)
      } else if let preview {
        Image(uiImage: preview)
          .resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 240)
          .accessibilityLabel(medium.label)
          .accessibilityIdentifier("\(medium.rawValue)CoverImage")
      } else if model.errors[medium] != nil {
        Label("Cover preview unavailable", systemImage: "photo.badge.exclamationmark")
          .frame(maxWidth: .infinity, minHeight: 160)
      } else if model.slot(medium) != nil {
        ProgressView("Loading cover…").frame(maxWidth: .infinity, minHeight: 160)
      } else {
        Label("No cover", systemImage: "book.closed").frame(maxWidth: .infinity, minHeight: 160)
      }
      if model.pendingURLs[medium] != nil {
        Text("Selected provider image. Choose Save to keep this image.")
          .fixedSize(horizontal: false, vertical: true)
      } else if let pending = model.pending[medium] {
        Text("Selected image: \(pending.width) × \(pending.height)")
        Text("Choose Save to keep this image.").font(.footnote)
      } else if let slot = model.slot(medium) {
        Text(slot.source == "custom" ? "Custom" : "Extracted")
        if let width = slot.width, let height = slot.height {
          Text("\(width) × \(height)").font(.footnote)
        }
      }
      if model.isLocked(medium) {
        Label("This cover is locked. Unlock it in metadata before editing.", systemImage: "lock")
      }
      if let error = model.errors[medium] {
        Label(error, systemImage: "exclamationmark.triangle")
      }
      if model.errors[medium] != nil || model.isLocked(medium) {
        Button("Reload cover") { Task { await model.reload(medium) } }
          .frame(minHeight: 44)
          .accessibilityIdentifier("reload\(medium.identifier)Cover")
          .disabled(model.isBusy)
      }
      if model.importing.contains(medium) { ProgressView("Preparing image…") }
      PhotosPicker(selection: $selection, matching: .images, preferredItemEncoding: .current) {
        Label("Choose \(medium.rawValue) image", systemImage: "photo")
          .frame(minHeight: 44)
      }
      .accessibilityIdentifier("choose\(medium.identifier)Cover")
      .disabled(model.isBusy || !model.canEdit(medium))
      .onChange(of: selection) { model.choose(selection, medium: medium) }
      Button("Find \(medium.rawValue) cover") { isFindingCover = true }
        .frame(minHeight: 44).accessibilityIdentifier("find\(medium.identifier)Cover")
        .disabled(model.isBusy || !model.canEdit(medium))
      if model.hasSelection(medium) {
        Button("Save \(medium.rawValue) cover") { Task { await model.save(medium) } }
          .frame(minHeight: 44)
          .accessibilityIdentifier("save\(medium.identifier)Cover")
          .disabled(model.isBusy || !model.canEdit(medium))
        Button("Discard \(medium.rawValue) selection") {
          model.discard(medium)
          selection = nil
        }.frame(minHeight: 44).disabled(model.isBusy)
      }
      if model.slot(medium)?.source == "custom" {
        Button("Revert \(medium.rawValue) cover") { isConfirmingRevert = true }
          .frame(minHeight: 44)
          .accessibilityIdentifier("revert\(medium.identifier)Cover")
          .disabled(model.isBusy || !model.canEdit(medium))
      }
      if model.canReExtractCovers {
        Button(action: reExtractCover) {
          Text(extractionLabel)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier("reExtract\(medium.identifier)Cover")
        .disabled(model.isBusy || !model.canEdit(medium))
        if model.slot(medium)?.source == "custom" {
          Text("Re-extraction refreshes the embedded cover and keeps your custom cover selected.")
            .font(.footnote)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .padding()
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    .alert("Revert \(medium.rawValue) cover?", isPresented: $isConfirmingRevert) {
      Button("Revert", role: .destructive) { Task { await model.revert(medium) } }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Remove the custom image and restore the extracted cover, if available.")
    }
    .sheet(isPresented: $isFindingCover) {
      CoverSearchView(api: model.api, book: model.book, medium: medium) { url in
        selection = nil
        model.chooseURL(url, medium: medium)
      }
    }
  }

  private func reExtractCover() { model.reExtract(medium) }
}
