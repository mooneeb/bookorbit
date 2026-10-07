import SwiftUI

struct EPUBPreferencesView: View {
  let model: EPUBPreferencesModel
  @State private var draft: EPUBPreferencesValue
  @Environment(\.dismiss) private var dismiss
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  init(model: EPUBPreferencesModel) {
    self.model = model
    _draft = State(initialValue: model.value)
  }

  var body: some View {
    NavigationStack {
      Form {
        Group {
          Section("Reading mode") {
            Picker("Reading mode", selection: $draft.settings.flow) {
              Text("Horizontal pagination").tag("paginated")
              Text("Continuous scrolling").tag("scrolled")
            }.accessibilityIdentifier("epubReadingMode")
            Picker("Page animation", selection: $draft.pageAnimation) {
              ForEach(ReaderTurnAnimation.allCases) { Text($0.label).tag($0) }
            }.accessibilityIdentifier("epubPageAnimation")
            if reduceMotion { Text("Reduce Motion uses immediate page changes.") }
            Text("Native page animation stays on this device.")
          }
          Section("Appearance") {
            Picker("Theme", selection: $draft.settings.themeName) {
              ForEach(EPUBThemeVocabulary.names, id: \.self) { name in
                Text(name.capitalized).tag(name)
              }
            }.accessibilityIdentifier("epubTheme")
            Toggle("Dark appearance", isOn: $draft.settings.isDark).accessibilityIdentifier(
              "epubDarkAppearance")
            Picker("Font", selection: fontFamily) {
              Text("Publisher font").tag("")
              ForEach(["Georgia", "Helvetica", "Palatino", "Times New Roman"], id: \.self) {
                Text($0).tag($0)
              }
              ForEach(model.fonts.selectableFamilies) { family in
                Text(family.label).tag(family.cssFamily)
              }
              if let family = draft.settings.fontFamily,
                !["Georgia", "Helvetica", "Palatino", "Times New Roman"].contains(family),
                !model.fonts.selectableFamilies.contains(where: { $0.cssFamily == family })
              {
                Text("Saved font: \(family) (unavailable)").tag(family)
              }
            }.accessibilityIdentifier("epubFontFamily")
            Stepper(
              "Font size: \(Int(draft.settings.fontSize))", value: $draft.settings.fontSize,
              in: 6...32
            )
            .accessibilityIdentifier("epubFontSize")
            if let family = customFamily {
              Picker("Font variant", selection: fontVariant) {
                ForEach(family.variants, id: \.variantID) { variant in
                  Text(variant.readerLabel).tag(variant.variantID)
                }
                if !family.variants.contains(where: {
                  $0.weight == draft.settings.fontWeight && $0.style == draft.settings.fontStyle
                }) {
                  Text("Saved: \(Int(draft.settings.fontWeight)) \(draft.settings.fontStyle)")
                    .tag("\(draft.settings.fontWeight):\(draft.settings.fontStyle)")
                }
              }.accessibilityIdentifier("epubFontVariant")
            } else {
              Stepper(
                "Font weight: \(Int(draft.settings.fontWeight))", value: $draft.settings.fontWeight,
                in: 100...900, step: 100
              )
              .accessibilityIdentifier("epubFontWeight")
              Picker("Font style", selection: $draft.settings.fontStyle) {
                Text("Normal").tag("normal")
                Text("Italic").tag("italic")
              }
            }
            Toggle(
              "Apply defaults instead of publisher formatting",
              isOn: $draft.settings.overrideBookFormatting)
            Text(
              "Per-book settings apply when customized. Fixed-layout books preserve publisher typography."
            )
          }
          Section("Text layout") {
            Slider(value: $draft.settings.lineHeight, in: 0.8...3, step: 0.1) {
              Text("Line height")
            }
            Text(
              "Line height: \(draft.settings.lineHeight.formatted(.number.precision(.fractionLength(1))))"
            )
            Slider(value: $draft.settings.paragraphSpacing, in: 0...2, step: 0.1) {
              Text("Paragraph spacing")
            }
            Text(
              "Paragraph spacing: \(draft.settings.paragraphSpacing.formatted(.number.precision(.fractionLength(1))))"
            )
            optionalSpacing(
              "Letter spacing", value: $draft.settings.letterSpacing, range: 0...0.2, step: 0.01)
            optionalSpacing(
              "Word spacing", value: $draft.settings.wordSpacing, range: 0...0.5, step: 0.01)
            optionalSpacing(
              "First-line indent", value: $draft.settings.textIndent, range: 0...4, step: 0.1)
            Toggle("Justify text", isOn: $draft.settings.justify)
            Toggle("Hyphenate words", isOn: $draft.settings.hyphenate)
          }
          Section("Page layout") {
            Stepper(
              "Maximum columns: \(Int(draft.settings.maxColumnCount))",
              value: $draft.settings.maxColumnCount, in: 1...10)
            Slider(value: $draft.settings.gap, in: 0...0.5, step: 0.01) { Text("Column gap") }
            Text("Column gap: \(Int(draft.settings.gap * 100)) percent")
            Stepper(
              "Maximum width: \(Int(draft.settings.maxInlineSize))",
              value: $draft.settings.maxInlineSize, in: 400...1600, step: 40)
            Stepper(
              "Maximum height: \(Int(draft.settings.maxBlockSize))",
              value: $draft.settings.maxBlockSize, in: 600...2400, step: 100)
            Picker("Fixed-layout facing pages", selection: $draft.settings.fixedLayoutSpread) {
              Text("Publisher layout").tag("auto")
              Text("Single page").tag("none")
            }.accessibilityIdentifier("epubFixedLayoutSpread")
            Picker("Reading position", selection: $draft.settings.footerDisplayMode) {
              Text("Page progress").tag(0)
              Text("Reading progress").tag(1)
              Text("Chapter progress").tag(2)
            }
          }
        }.disabled(model.isSaving || model.hasPendingSave)
        Section("Custom fonts") {
          if model.fonts.isLoading { ProgressView("Loading font catalog…") }
          if model.fonts.isSaving { ProgressView("Saving font visibility…") }
          if let error = model.fonts.error {
            Text(error).fixedSize(horizontal: false, vertical: true)
              .accessibilityIdentifier("epubFontCatalogError")
          }
          Button("Reload font catalog", action: reloadFonts).frame(minHeight: 44)
            .disabled(
              model.fonts.isLoading || model.fonts.isSaving || model.fonts.hasPendingSave
                || model.isSaving || model.hasPendingSave
            )
            .accessibilityIdentifier("epubReloadFonts")
          if model.fonts.hasPendingSave {
            Button("Retry font visibility change", action: retryFontVisibility).frame(minHeight: 44)
              .disabled(model.fonts.isSaving).accessibilityIdentifier("epubRetryFontVisibility")
          }
          ForEach(model.fonts.serverFamilies) { family in
            Toggle("Show \(family.name)", isOn: visibility(family))
              .disabled(
                model.fonts.isSaving || model.fonts.hasPendingSave || model.isSaving
                  || model.hasPendingSave)
          }
          Text(
            "Font visibility belongs to your account. Custom typography applies to reflowable books."
          )
        }
        Section("Remember settings") {
          Text(
            model.syncSettings
              ? "Appearance syncs with your account."
              : "Settings stay on this device, separately for each server and account.")
          if model.syncSettings && !model.canSync {
            Text("This account cannot change synchronized reader defaults.")
          }
          Button("Use defaults for this book", action: useDefaults).frame(minHeight: 44)
            .disabled(!canSave).accessibilityIdentifier("epubUseDefaults")
          Button("Save as defaults and for this book", action: saveDefaults).frame(minHeight: 44)
            .disabled(!canSave || (model.syncSettings && !model.canSync)).accessibilityIdentifier(
              "epubSaveDefaults")
        }
        if let error = model.error {
          Section {
            Text(error).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier(
              "epubPreferencesError")
            if model.hasPendingSave {
              Button("Retry the same save", action: retry).frame(minHeight: 44)
                .disabled(model.isSaving).accessibilityIdentifier("epubRetrySettings")
            }
            Button("Reload saved settings", action: reload).frame(minHeight: 44).disabled(
              model.isSaving)
          }
        }
        if model.isSaving { ProgressView("Saving reader settings…") }
      }
      .navigationTitle("Reader settings")
      .safeAreaInset(edge: .bottom) {
        HStack {
          Button("Cancel", action: dismiss.callAsFunction).frame(minHeight: 44)
            .disabled(
              model.isSaving || model.hasPendingSave || model.fonts.isSaving
                || model.fonts.hasPendingSave)
          Spacer()
          Button("Save for this book", action: saveBook).frame(minHeight: 44)
            .disabled(!canSave).accessibilityIdentifier("epubSaveSettings")
        }.buttonStyle(.plain).padding().background(.background)
      }
    }
    .interactiveDismissDisabled(
      model.isSaving || model.hasPendingSave || model.fonts.isSaving || model.fonts.hasPendingSave
    )
    .task { await model.fonts.load() }
  }

  private var canSave: Bool {
    draft.isValid && model.canSave && !model.hasPendingSave && !model.fonts.isLoading
      && !model.fonts.isSaving && !model.fonts.hasPendingSave
  }
  private var customFamily: EPUBFontFamily? { try? model.fonts.resolve(draft.settings.fontFamily) }
  private var fontFamily: Binding<String> {
    Binding(
      get: { draft.settings.fontFamily ?? "" },
      set: { selected in
        draft.settings.fontFamily = selected.isEmpty ? nil : selected
        if let family = customFamily {
          let sameStyle = family.variants.filter { $0.style == draft.settings.fontStyle }
          let candidates = sameStyle.isEmpty ? family.variants : sameStyle
          if let closest = candidates.min(by: {
            abs($0.weight - draft.settings.fontWeight) < abs($1.weight - draft.settings.fontWeight)
          }) {
            draft.settings.fontWeight = closest.weight
            draft.settings.fontStyle = closest.style
          }
        }
      })
  }
  private var fontVariant: Binding<String> {
    Binding(
      get: { "\(draft.settings.fontWeight):\(draft.settings.fontStyle)" },
      set: { selected in
        if let variant = customFamily?.variants.first(where: { $0.variantID == selected }) {
          draft.settings.fontWeight = variant.weight
          draft.settings.fontStyle = variant.style
        }
      })
  }
  private func visibility(_ family: EPUBFontFamily) -> Binding<Bool> {
    Binding(
      get: { !model.fonts.hiddenFamilies.contains(family.name) },
      set: { visible in
        Task { await model.fonts.setHidden(family, hidden: !visible) }
      })
  }
  private func reloadFonts() { Task { await model.fonts.load() } }
  private func retryFontVisibility() { Task { await model.fonts.retryVisibility() } }
  private func optionalSpacing(
    _ title: String, value: Binding<Double?>, range: ClosedRange<Double>, step: Double
  ) -> some View {
    VStack(alignment: .leading) {
      Toggle(
        "Customize \(title.lowercased())",
        isOn: Binding(
          get: { value.wrappedValue != nil },
          set: { value.wrappedValue = $0 ? range.lowerBound : nil }))
      if value.wrappedValue != nil {
        Slider(
          value: Binding(
            get: { value.wrappedValue ?? range.lowerBound }, set: { value.wrappedValue = $0 }),
          in: range, step: step
        ) { Text(title) }
        Text(
          "\(title): \((value.wrappedValue ?? 0).formatted(.number.precision(.fractionLength(2))))")
      }
    }
  }
  private func saveBook() { Task { if await model.save(draft, asDefault: false) { dismiss() } } }
  private func saveDefaults() { Task { if await model.save(draft, asDefault: true) { dismiss() } } }
  private func useDefaults() { Task { if await model.useDefaults() { dismiss() } } }
  private func retry() { Task { if await model.retry() { dismiss() } } }
  private func reload() {
    Task {
      await model.reloadSavedSettings()
      if model.hasLoaded { draft = model.value }
    }
  }
}

extension FontNamedInstance {
  fileprivate var variantID: String { "\(weight):\(style)" }
  fileprivate var readerLabel: String {
    name ?? "\(Int(weight)) \(style == "italic" ? "Italic" : "Normal")"
  }
}
