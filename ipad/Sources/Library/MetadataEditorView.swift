import SwiftUI

struct MetadataEditorView: View {
  @Bindable var model: BookDetailModel
  @Bindable var draft: MetadataDraft
  @Environment(\.dismiss) private var dismiss
  @State private var isFindingMetadata = false
  @State private var previewSource: MetadataPreviewSource?
  @State private var isWritingFiles = false

  var body: some View {
    VStack(spacing: 0) {
      Text("Edit metadata")
        .font(.headline)
        .frame(maxWidth: .infinity, minHeight: 44)
        .padding(.horizontal)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("metadataHeading")
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
              HStack(spacing: 16) { allLockActions }
              VStack(alignment: .leading, spacing: 8) { allLockActions }
            }
            Text("Lock changes are saved with the metadata.")
              .font(.footnote).fixedSize(horizontal: false, vertical: true)
          }
          Button("Find and compare metadata") { isFindingMetadata = true }
            .frame(minHeight: 44).accessibilityIdentifier("findMetadata")
          Button {
            previewSource = .automatic
          } label: {
            Text("Preview automatic metadata").frame(minHeight: 44).contentShape(Rectangle())
          }.accessibilityIdentifier("previewAutomaticMetadata")
          Button {
            previewSource = .embedded
          } label: {
            Text("Compare metadata from file").frame(minHeight: 44).contentShape(Rectangle())
          }.accessibilityIdentifier("previewEmbeddedMetadata")
          Button("Write saved metadata and rename files", action: promptFileWrite)
            .frame(minHeight: 44).accessibilityIdentifier("writeSavedMetadataAndRename")
          Text(
            "This source-file operation uses saved server metadata. It does not save your current editor changes."
          )
          .font(.footnote).fixedSize(horizontal: false, vertical: true)
          if !draft.coverURLs.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
              ForEach(draft.coverURLs.keys.sorted(by: { $0.rawValue < $1.rawValue })) { medium in
                Text("\(medium.label) selected from provider.")
                Button("Discard \(medium.rawValue) cover selection") {
                  draft.coverURLs[medium] = nil
                }
                .frame(minHeight: 44)
              }
            }
          }
          VStack(alignment: .leading, spacing: 12) {
            HStack {
              Text("Title").font(.headline)
              Spacer()
              MetadataClearButton(text: $draft.title, label: "Title", identifier: "metadataTitle")
                .disabled(draft.lockedFields.contains("title"))
            }
            MetadataTextInput(text: $draft.title, label: "Title", identifier: "metadataTitle")
              .disabled(draft.lockedFields.contains("title"))
              .fixedSize(horizontal: false, vertical: true)
            MetadataFieldLock(
              draft: draft, field: "title", label: "Lock title", identifier: "metadataTitleLock")
            Divider()
            HStack {
              Text("Subtitle").font(.headline)
              Spacer()
              MetadataClearButton(
                text: $draft.subtitle, label: "Subtitle", identifier: "metadataSubtitle"
              )
              .disabled(draft.lockedFields.contains("subtitle"))
            }
            MetadataTextInput(
              text: $draft.subtitle, label: "Subtitle", identifier: "metadataSubtitle"
            )
            .disabled(draft.lockedFields.contains("subtitle"))
            .fixedSize(horizontal: false, vertical: true)
            MetadataFieldLock(
              draft: draft, field: "subtitle", label: "Lock subtitle",
              identifier: "metadataSubtitleLock")
          }
          VStack(alignment: .leading, spacing: 12) {
            Text("Description").font(.headline)
            RichDescriptionEditorView(
              html: $draft.description, isLocked: draft.lockedFields.contains("description")
            )
            .id("\(draft.id)-\(draft.resetGeneration)")
            MetadataFieldLock(
              draft: draft, field: "description", label: "Lock description",
              identifier: "metadataDescriptionLock")
          }
          VStack(alignment: .leading, spacing: 20) {
            Text("Publication").font(.title2)
            MetadataScalarField(
              draft: draft, text: $draft.publisher, field: "publisher", label: "Publisher",
              identifier: "metadataPublisher", model: model)
            MetadataScalarField(
              draft: draft,
              text: Binding(get: { draft.publishedYear }, set: draft.setPublishedYear),
              field: "publishedYear", label: "Published year", identifier: "metadataPublishedYear",
              keyboard: .numberPad, locked: draft.isPublicationLocked, showsLock: false)
            MetadataScalarField(
              draft: draft,
              text: Binding(get: { draft.publishedDate }, set: draft.setPublishedDate),
              field: "publishedYear", label: "Published date (YYYY-MM-DD)",
              identifier: "metadataPublishedDate", locked: draft.isPublicationLocked,
              lockLabel: "Lock publication date and year")
            Text("The date sets the year. Changing the year clears the date.")
              .font(.footnote)
            MetadataScalarField(
              draft: draft, text: $draft.pageCount, field: "pageCount", label: "Page count",
              identifier: "metadataPageCount", keyboard: .numberPad)
            MetadataScalarField(
              draft: draft, text: $draft.language, field: "language", label: "Language",
              identifier: "metadataLanguage", model: model)
            MetadataScalarField(
              draft: draft, text: $draft.isbn10, field: "isbn10", label: "ISBN-10",
              identifier: "metadataISBN10")
            MetadataScalarField(
              draft: draft, text: $draft.isbn13, field: "isbn13", label: "ISBN-13",
              identifier: "metadataISBN13")
          }
          VStack(alignment: .leading, spacing: 20) {
            Text("People and organization").font(.title2)
            Text("Enter one name per line. Commas stay part of the name.").font(.footnote)
            MetadataNamesField(
              model: model, draft: draft, text: $draft.authors, field: "authors", label: "Authors",
              identifier: "metadataAuthors")
            MetadataNamesField(
              model: model, draft: draft, text: $draft.genres, field: "genres", label: "Genres",
              identifier: "metadataGenres")
            MetadataNamesField(
              model: model, draft: draft, text: $draft.tags, field: "tags", label: "Tags",
              identifier: "metadataTags")
          }
          VStack(alignment: .leading, spacing: 12) {
            Text("Covers").font(.title2)
            ForEach(model.book?.coverMedia ?? []) { medium in
              MetadataFieldLock(
                draft: draft, field: medium.lockField,
                label: "Lock \(medium.rawValue) cover",
                identifier: "metadata\(medium == .ebook ? "" : "Audio")CoverLock")
            }
          }
          MetadataExtraFieldsView(model: model, draft: draft, extra: draft.extra)
          if !draft.customFields.isEmpty { CustomMetadataFieldsView(fields: $draft.customFields) }
        }
        .padding()
      }
      .scrollEdgeEffectHidden()
      .clipped()
      .disabled(model.isSaving || model.fileWriteBlocksMetadata)
      .safeAreaInset(edge: .bottom) {
        VStack(alignment: .leading) {
          if let error = model.error {
            Label(error, systemImage: "exclamationmark.triangle")
              .accessibilityIdentifier("metadataSaveError")
          }
          if model.isSaving { ProgressView("Saving metadata…") }
          if model.fileWriteBlocksMetadata || model.book == nil {
            Text(
              "Review source-file status and reload current book details before saving more changes."
            )
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("metadataFileWritePending")
            Button("Review source-file status", action: promptFileWrite)
              .frame(minHeight: 44).accessibilityIdentifier("metadataReviewFileWriteStatus")
          }
          if let message = draft.validationMessage {
            Label(
              message,
              systemImage: "exclamationmark.circle")
          }
          ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
              cancelButton
              resetButton
              Spacer()
              keyboardButton
              saveButton
            }
            VStack(alignment: .leading, spacing: 8) {
              HStack {
                cancelButton
                Spacer()
                saveButton
              }
              HStack {
                resetButton
                Spacer()
                keyboardButton
              }
            }
            VStack(alignment: .leading, spacing: 8) {
              cancelButton
              resetButton
              keyboardButton
              saveButton
            }
          }
          .frame(minHeight: 44)
        }
        .buttonStyle(MetadataActionButtonStyle())
        .font(.body)
        .foregroundStyle(.primary)
        .padding(.horizontal)
        .background(.background)
      }
      .interactiveDismissDisabled(model.isSaving)
    }
    .background(Color(uiColor: .systemBackground))
    .sheet(isPresented: $isWritingFiles) {
      if let fileWrite = model.fileWrite { BookWriteAndRenameView(model: fileWrite) }
    }
    .fullScreenCover(item: $previewSource) { source in
      MetadataPreviewView(api: model.api, bookID: model.bookID, source: source, draft: draft) {
        previewSource = nil
      }
    }
    .fullScreenCover(isPresented: $isFindingMetadata) {
      if let book = model.book {
        MetadataSearchView(api: model.api, book: book, draft: draft) { isFindingMetadata = false }
      }
    }
  }

  private func promptFileWrite() {
    model.beginWritingFiles()
    if model.fileWrite != nil { isWritingFiles = true }
  }

  @ViewBuilder private var allLockActions: some View {
    Button(action: draft.lockAll) {
      Label("Lock all", systemImage: "lock")
        .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
    }
    .disabled(draft.areAllLocked)
    .accessibilityIdentifier("metadataLockAll")
    Button(action: draft.unlockAll) {
      Label("Unlock all", systemImage: "lock.open")
        .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
    }
    .disabled(draft.lockedFields.isEmpty)
    .accessibilityIdentifier("metadataUnlockAll")
  }

  private var cancelButton: some View {
    Button(action: dismiss.callAsFunction) {
      Text("Cancel").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
    }
    .disabled(model.isSaving)
  }

  private var resetButton: some View {
    Button(action: model.resetMetadata) {
      Label("Reset", systemImage: "arrow.counterclockwise")
        .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
    }
    .disabled(model.isSaving)
    .accessibilityHint("Discard unsaved metadata, lock changes, and cover selections")
    .accessibilityIdentifier("metadataReset")
  }

  private var keyboardButton: some View {
    Button {
      UIApplication.shared.sendAction(
        #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    } label: {
      Label("Hide keyboard", systemImage: "keyboard.chevron.compact.down")
        .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
    }
    .accessibilityIdentifier("metadataDismissKeyboard")
  }

  private var saveButton: some View {
    Button {
      Task { await model.saveMetadata() }
    } label: {
      Label("Save", systemImage: draft.isValid ? "checkmark" : "exclamationmark.circle")
        .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
    }
    .disabled(
      model.book == nil || model.isSaving || model.fileWriteBlocksMetadata || !draft.isValid
    )
    .accessibilityIdentifier("saveMetadata")
  }
}

private struct MetadataScalarField: View {
  @Bindable var draft: MetadataDraft
  @Binding var text: String
  let field: String
  let label: String
  let identifier: String
  var model: BookDetailModel? = nil
  var keyboard: UIKeyboardType = .default
  var locked = false
  var showsLock = true
  var lockLabel: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(label).font(.headline)
      HStack {
        TextField("", text: $text)
          .textFieldStyle(.roundedBorder)
          .keyboardType(keyboard)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .frame(minHeight: 44)
          .accessibilityLabel(label)
          .accessibilityIdentifier(identifier)
        MetadataClearButton(text: $text, label: label, identifier: identifier)
      }
      .disabled(locked || draft.lockedFields.contains(field))
      if let model, let suggestionField = MetadataDraftSuggestionField(rawValue: field) {
        MetadataDraftSuggestionButton(
          model: model, draft: draft, text: $text, field: suggestionField, label: label,
          identifier: identifier)
      }
      if showsLock {
        MetadataFieldLock(
          draft: draft, field: field, label: lockLabel ?? "Lock \(label.lowercased())",
          identifier: "\(identifier)Lock")
      }
    }
  }
}

private struct MetadataNamesField: View {
  @Bindable var model: BookDetailModel
  @Bindable var draft: MetadataDraft
  @Binding var text: String
  let field: String
  let label: String
  let identifier: String

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(label).font(.headline).foregroundStyle(Color(uiColor: .label))
        Spacer()
        MetadataClearButton(text: $text, label: label, identifier: identifier)
          .disabled(draft.lockedFields.contains(field))
      }
      MetadataTextInput(text: $text, label: label, identifier: identifier)
        .disabled(draft.lockedFields.contains(field))
        .fixedSize(horizontal: false, vertical: true)
      if let suggestionField = MetadataDraftSuggestionField(rawValue: field) {
        MetadataDraftSuggestionButton(
          model: model, draft: draft, text: $text, field: suggestionField, label: label,
          identifier: identifier)
      }
      MetadataFieldLock(
        draft: draft, field: field, label: "Lock \(label.lowercased())",
        identifier: "\(identifier)Lock")
    }
  }
}

private struct MetadataClearButton: View {
  @Binding var text: String
  let label: String
  let identifier: String

  var body: some View {
    Button {
      text = ""
    } label: {
      Image(systemName: "xmark.circle")
        .frame(minWidth: 44, minHeight: 44)
    }
    .buttonStyle(.borderless)
    .accessibilityLabel("Clear \(label.lowercased())")
    .accessibilityIdentifier("\(identifier)Clear")
    .disabled(text.isEmpty)
  }
}

private struct MetadataActionButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(Color(uiColor: .label))
      .padding(.vertical, 10)
      .contentShape(Rectangle())
      .opacity(configuration.isPressed ? 0.7 : 1)
  }
}

struct MetadataFieldLock: View {
  @Bindable var draft: MetadataDraft
  let field: String
  let label: String
  let identifier: String

  var body: some View {
    Toggle(
      label,
      isOn: Binding(
        get: { draft.lockedFields.contains(field) },
        set: { locked in
          if locked { draft.lockedFields.insert(field) } else { draft.lockedFields.remove(field) }
        })
    )
    .foregroundStyle(Color(uiColor: .label))
    .accessibilityIdentifier(identifier)
  }
}
