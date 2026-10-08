import SwiftUI

struct PDFPassageAnnotationControls: View {
  let model: PDFPassageAnnotationModel
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Private passage notes").font(.headline)
      HStack {
        Button("Select PDF text", action: model.beginSelection)
          .disabled(model.isBusy).accessibilityIdentifier("pdfPassageSelectText")
        Button("Preview selected passage", action: model.previewSelection)
          .disabled(!model.canPreview).accessibilityIdentifier("pdfPassagePreview")
        Button("Undo passage annotation", action: model.undo)
          .disabled(!model.canUndo).accessibilityIdentifier("pdfPassageUndo")
        if annotationInputFixture {
          Button("Select fixture PDF text", action: model.feedSelection)
            .disabled(!model.canManage || model.isBusy)
            .accessibilityIdentifier("pdfPassageFixtureSelection")
        }
      }.frame(minHeight: 44)
      if !model.visibleNotes.isEmpty {
        Menu("Passage notes on these pages") {
          ForEach(model.visibleNotes, id: \.id) { item in
            Button(item.text.isEmpty ? "Passage note" : String(item.text.prefix(80))) {
              model.open(item)
            }
            .accessibilityIdentifier("pdfPassageOpen\(item.id)")
          }
        }.frame(minHeight: 44).accessibilityIdentifier("pdfPassageNotes")
      }
      if !model.selectedText.isEmpty {
        Text(model.selectedText).lineLimit(2).accessibilityIdentifier("pdfPassageSelectedText")
      }
      if !model.canManage { Text("Passage annotation editing requires permission.").font(.caption) }
      if let notice = model.notice {
        Text(notice).font(.caption).accessibilityIdentifier("pdfPassageNotice")
      }
      if let error = model.error {
        Text(error).font(.caption).accessibilityIdentifier("pdfPassageError")
      }
    }.padding()
  }
}

struct PDFPassageAnnotationView: View {
  @Bindable var model: PDFPassageAnnotationModel
  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          Text("Selected passage").font(.headline)
          Text(verbatim: model.presentation?.preview.text ?? "")
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("pdfPassageSelectionPreview")
          Picker("Annotation kind", selection: $model.kind) {
            Text("Highlight").tag("highlight")
            Text("Text note").tag("text_note")
            Text("Handwriting").tag("handwriting")
          }.pickerStyle(.segmented).disabled(model.presentation?.item != nil || !model.canManage)
            .accessibilityIdentifier("pdfPassageKind")
          Picker("Highlight color", selection: $model.color) {
            Text("Yellow").tag("#FACC15")
            Text("Green").tag("#4ADE80")
            Text("Blue").tag("#60A5FA")
            Text("Pink").tag("#F472B6")
          }.disabled(!model.canManage).accessibilityIdentifier("pdfPassageColor")
          if model.kind == "text_note" {
            Text("Type or use English Scribble in the note field.").font(.caption)
            EnglishScribbleTextView(
              text: $model.note, fixtureGeneration: model.scribbleFixtureGeneration
            )
            .frame(minHeight: 180).disabled(!model.canManage)
            if annotationInputFixture {
              Button("Complete fixture English Scribble", action: model.completeFixtureScribble)
                .disabled(!model.canManage).accessibilityIdentifier("pdfPassageFixtureScribble")
            }
          }
          if model.kind == "handwriting" {
            Text("This retained handwriting belongs to the passage and stays private.").font(
              .caption)
            PencilModeControls(mode: model.mode).disabled(!model.canManage)
            ScrollView(.horizontal) {
              PencilPassageCanvas(
                drawing: $model.drawing, mode: model.mode,
                fixtureGeneration: model.fixtureGeneration, usesBlueFixture: annotationInputFixture
              )
              .frame(width: 640, height: 360).fixedSize().allowsHitTesting(model.canManage)
            }
            Text("\(model.drawing.strokes.count) retained strokes")
              .accessibilityIdentifier("pdfPassageRetainedStrokeCount")
            if annotationInputFixture {
              Button("Add fixture Pencil stroke", action: model.addFixtureStroke)
                .disabled(!model.canManage).accessibilityIdentifier("pdfPassageFixtureStroke")
            }
          }
          if let error = model.error { Text(error).accessibilityIdentifier("pdfPassageSaveError") }
          if model.presentation?.item != nil {
            Button("Delete annotation", role: .destructive, action: model.delete)
              .disabled(!model.canManage || model.isBusy).accessibilityIdentifier(
                "pdfPassageDelete")
          }
        }.padding()
      }
      .navigationTitle(
        model.presentation?.item == nil ? "Mark PDF passage" : "Edit PDF passage note"
      )
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel", action: model.cancel).disabled(model.isBusy).accessibilityIdentifier(
            "pdfPassageCancel")
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save", action: model.save).disabled(!model.canSave).accessibilityIdentifier(
            "pdfPassageSave")
        }
      }
    }.interactiveDismissDisabled(model.isBusy).presentationDetents([.large])
  }
}
