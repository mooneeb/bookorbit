import SwiftUI

struct ReaderPreferencesView: View {
  let model: ReaderPreferencesModel
  @State private var draft: ReaderPreferencesValue
  @Environment(\.dismiss) private var dismiss
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  init(model: ReaderPreferencesModel) {
    self.model = model
    _draft = State(initialValue: model.value)
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("Page animation on this device") {
          Picker("Page animation", selection: $draft.pageAnimation) {
            ForEach(ReaderTurnAnimation.allCases) { Text($0.label).tag($0) }
          }
          .accessibilityIdentifier("readerAnimation")
          if reduceMotion { Text("Reduce Motion uses immediate page changes.") }
        }
        Section("Appearance") {
          if model.group == "pdf" {
            Picker("Page fit", selection: $draft.pdf.zoomMode) {
              Text("Fit page").tag("fit-page")
              Text("Fit width").tag("fit-width")
              Text("Automatic").tag("automatic")
              Text("Custom zoom").tag("custom")
            }
            .accessibilityIdentifier("readerPageFit")
            if draft.pdf.zoomMode == "custom" {
              Slider(value: $draft.pdf.customScale, in: 0.25...4, step: 0.25) {
                Text("Zoom")
              }
              .accessibilityValue("\(Int(draft.pdf.customScale * 100)) percent")
              Text("Zoom: \(Int(draft.pdf.customScale * 100)) percent")
            }
            Picker("Page rotation", selection: $draft.pdf.rotation) {
              ForEach([0, 90, 180, 270], id: \.self) { value in
                Text("\(value) degrees").tag(value)
              }
            }
            .accessibilityIdentifier("readerRotation")
          } else {
            Picker("Page fit", selection: $draft.comic.fitMode) {
              Text("Fit page").tag("fit-page")
              Text("Fit width").tag("fit-width")
              Text("Fit height").tag("fit-height")
              Text("Actual size").tag("actual")
            }
            .accessibilityIdentifier("readerPageFit")
            Picker("Page background", selection: $draft.comic.bgColor) {
              Text("Black").tag("black")
              Text("Gray").tag("gray")
              Text("White").tag("white")
            }
            .accessibilityIdentifier("readerBackground")
          }
        }
        Section("Page layout") {
          if model.group == "pdf" {
            Picker("Reading mode", selection: $draft.pdf.scrollMode) {
              Text("Paged").tag("page")
              Text("Continuous vertical").tag("vertical")
              Text("Continuous horizontal").tag("horizontal")
            }.accessibilityIdentifier("readerScrollMode")
            Picker("Facing pages", selection: $draft.pdf.spread) {
              Text("Single page").tag("none")
              Text("Pairs from page one").tag("odd")
              Text("Cover, then pairs").tag("even")
              Text("Automatic on wide screens").tag("auto")
            }.accessibilityIdentifier("readerFacingPages")
          } else {
            Picker("Reading mode", selection: $draft.comic.scrollMode) {
              Text("Paged").tag("paginated")
              Text("Continuous vertical").tag("infinite")
              Text("Long strip").tag("long-strip")
            }.accessibilityIdentifier("readerScrollMode")
            Picker("Facing pages", selection: $draft.comic.viewMode) {
              Text("Single page").tag("single")
              Text("Two pages on wide screens").tag("two-page")
            }.accessibilityIdentifier("readerFacingPages")
            Text("Facing pages apply in paged mode. The cover remains a single page.")
            Toggle("Use two pages in portrait", isOn: $draft.comic.forceTwoPage)
              .accessibilityIdentifier("readerForceFacingPages")
            Picker("Reading direction", selection: $draft.comic.direction) {
              Text("Left to right").tag("ltr")
              Text("Right to left").tag("rtl")
            }.accessibilityIdentifier("readerDirection")
            Picker("Pair alignment", selection: $draft.comic.spreadAlignment) {
              Text("Cover, then pairs").tag("normal")
              Text("Cover and page two, then pairs").tag("shifted")
            }.accessibilityIdentifier("readerSpreadAlignment")
            Stepper(
              "Space between pages: \(draft.comic.spreadGap)", value: $draft.comic.spreadGap,
              in: ReaderLayoutBounds.spreadGapMinimum...ReaderLayoutBounds.spreadGapMaximum
            )
            .accessibilityIdentifier("readerSpreadGap")
          }
        }
        Section("Remember settings") {
          Text(
            model.syncLook
              ? "Page settings sync with your account. Native page animation stays on this device."
              : "Settings stay on this device, separately for each server and account.")
          Text("Save as defaults also applies these settings to this book.")
          Button("Use defaults for this book", action: useDefaults)
            .frame(minHeight: 44)
            .disabled(!canSave)
            .accessibilityIdentifier("readerUseDefaults")
          Button("Save as defaults", action: saveDefaults)
            .frame(minHeight: 44)
            .disabled(!canSave)
            .accessibilityIdentifier("readerSaveDefaults")
        }
        if let error = model.error {
          Text(error).fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("readerPreferencesError")
          Button("Reload settings", action: reloadSettings)
            .frame(minHeight: 44)
            .disabled(model.isLoading || model.isSaving)
        }
        if model.isSaving { ProgressView("Saving reader settings…") }
      }
      .navigationTitle("Reader settings")
      .navigationBarTitleDisplayMode(.inline)
      .safeAreaInset(edge: .bottom) {
        HStack {
          Button("Cancel", action: dismiss.callAsFunction)
            .frame(minWidth: 44, minHeight: 44)
            .disabled(model.isSaving)
          Spacer()
          Button("Save for this book", action: saveBook)
            .frame(minHeight: 44)
            .disabled(!canSave)
            .accessibilityIdentifier("readerSaveSettings")
        }
        .buttonStyle(.plain)
        .font(.body)
        .frame(minHeight: 44)
        .padding()
        .background(.background)
      }
    }
    .interactiveDismissDisabled(model.isSaving)
  }

  private var canSave: Bool {
    draft.isValid && model.hasLoaded && !model.isSaving && !model.isLoading
      && (!model.syncLook || model.canSync)
  }

  private func saveBook() { save(asDefault: false) }
  private func saveDefaults() { save(asDefault: true) }
  private func save(asDefault: Bool) {
    Task { if await model.save(draft, asDefault: asDefault) { dismiss() } }
  }
  private func useDefaults() { Task { if await model.useDefaults() { dismiss() } } }
  private func reloadSettings() {
    Task {
      await model.load()
      if model.hasLoaded { draft = model.value }
    }
  }
}
