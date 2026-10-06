import SwiftUI

struct MetadataEditorView: View {
  @Bindable var model: BookDetailModel
  @Bindable var draft: MetadataDraft
  @Environment(\.dismiss) private var dismiss
  @State private var isFindingMetadata = false

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
          Button("Find and compare metadata") { isFindingMetadata = true }
            .frame(minHeight: 44).accessibilityIdentifier("findMetadata")
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
            TextEditor(text: $draft.description)
              .disabled(draft.lockedFields.contains("description"))
              .frame(minHeight: 140)
              .accessibilityLabel("Description")
              .accessibilityIdentifier("metadataDescription")
            MetadataFieldLock(
              draft: draft, field: "description", label: "Lock description",
              identifier: "metadataDescriptionLock")
          }
          VStack(alignment: .leading, spacing: 20) {
            Text("Publication").font(.title2)
            MetadataScalarField(
              draft: draft, text: $draft.publisher, field: "publisher", label: "Publisher",
              identifier: "metadataPublisher")
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
              identifier: "metadataLanguage")
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
              draft: draft, text: $draft.authors, field: "authors", label: "Authors",
              identifier: "metadataAuthors")
            MetadataNamesField(
              draft: draft, text: $draft.genres, field: "genres", label: "Genres",
              identifier: "metadataGenres")
            MetadataNamesField(
              draft: draft, text: $draft.tags, field: "tags", label: "Tags",
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
          MetadataExtraFieldsView(draft: draft, extra: draft.extra)
          if !draft.customFields.isEmpty { CustomMetadataFieldsView(fields: $draft.customFields) }
        }
        .padding()
      }
      .scrollEdgeEffectHidden()
      .clipped()
      .disabled(model.isSaving)
      .safeAreaInset(edge: .bottom) {
        VStack(alignment: .leading) {
          if let error = model.error {
            Label(error, systemImage: "exclamationmark.triangle")
              .accessibilityIdentifier("metadataSaveError")
          }
          if model.isSaving { ProgressView("Saving metadata…") }
          if let message = draft.validationMessage {
            Label(
              message,
              systemImage: "exclamationmark.circle")
          }
          HStack {
            Button("Cancel", action: dismiss.callAsFunction)
              .disabled(model.isSaving)
            Spacer()
            Button("Hide keyboard", systemImage: "keyboard.chevron.compact.down") {
              UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
            .accessibilityIdentifier("metadataDismissKeyboard")
            Button {
              Task { await model.saveMetadata() }
            } label: {
              Label("Save", systemImage: draft.isValid ? "checkmark" : "exclamationmark.circle")
            }
            .disabled(model.isSaving || !draft.isValid)
            .accessibilityIdentifier("saveMetadata")
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
    .fullScreenCover(isPresented: $isFindingMetadata) {
      if let book = model.book {
        MetadataSearchView(api: model.api, book: book, draft: draft) { isFindingMetadata = false }
      }
    }
  }
}

private struct MetadataScalarField: View {
  @Bindable var draft: MetadataDraft
  @Binding var text: String
  let field: String
  let label: String
  let identifier: String
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
      if showsLock {
        MetadataFieldLock(
          draft: draft, field: field, label: lockLabel ?? "Lock \(label.lowercased())",
          identifier: "\(identifier)Lock")
      }
    }
  }
}

private struct MetadataNamesField: View {
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
