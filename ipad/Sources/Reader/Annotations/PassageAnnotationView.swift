import PencilKit
import SwiftUI

struct PassageAnnotationView: View {
  @Bindable var model: PassageAnnotationModel

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          Text("Selected passage").font(.headline)
          Text(verbatim: model.presentation?.passage.text ?? "")
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("passageSelectionPreview")
          Picker("Annotation kind", selection: $model.kind) {
            Text("Highlight").tag("highlight")
            Text("Text note").tag("text_note")
            Text("Handwriting").tag("handwriting")
          }.pickerStyle(.segmented).disabled(model.presentation?.item != nil)
            .accessibilityIdentifier("passageKind")
          if model.kind == "text_note" {
            Text("Type or use English Scribble in the note field.").font(.caption)
            EnglishScribbleTextView(
              text: $model.note, fixtureGeneration: model.scribbleFixtureGeneration,
              canEdit: model.canManage
            ).frame(minHeight: 180).disabled(!model.canManage)
            if annotationInputFixture {
              Button(action: model.completeFixtureScribble) {
                Text("Complete fixture English Scribble")
                  .font(.body)
                  .fixedSize(horizontal: false, vertical: true)
                  .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                  .contentShape(Rectangle())
              }
              .accessibilityIdentifier("passageFixtureScribble")
            }
          }
          if model.kind == "handwriting" {
            Text("Handwriting stays in this passage canvas when book text reflows.").font(.caption)
            PencilModeControls(mode: model.mode)
            ScrollView(.horizontal) {
              PencilPassageCanvas(
                drawing: $model.drawing, mode: model.mode,
                fixtureGeneration: model.fixtureGeneration, usesBlueFixture: model.usesBlueFixture,
                canEdit: model.canManage
              )
              .frame(width: 640, height: 360).fixedSize().disabled(!model.canManage)
            }
            Text("\(model.drawing.strokes.count) retained strokes").font(.caption)
              .accessibilityIdentifier("passageRetainedStrokeCount")
            if annotationInputFixture {
              Button(action: model.addFixtureStroke) {
                Text("Add fixture Pencil stroke")
                  .font(.body)
                  .fixedSize(horizontal: false, vertical: true)
                  .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                  .contentShape(Rectangle())
              }
              .accessibilityIdentifier("passageFixtureStroke")
              Button(action: model.addBlueFixtureStroke) {
                Text("Add blue transformed fixture stroke")
                  .font(.body)
                  .fixedSize(horizontal: false, vertical: true)
                  .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                  .contentShape(Rectangle())
              }
              .accessibilityIdentifier("passageFixtureBlueStroke")
            }
          }
          if let error = model.error {
            Text(error).foregroundStyle(.red).accessibilityIdentifier("passageError")
          }
          if model.canManage, model.presentation?.item != nil {
            Button(role: .destructive, action: model.delete) {
              Text("Delete annotation")
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .disabled(model.isSaving).accessibilityIdentifier("passageDelete")
          }
        }.padding()
      }
      .navigationTitle(model.presentation?.item == nil ? "Mark passage" : "Edit passage note")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(action: model.cancel) {
            Text("Cancel")
              .font(.body)
              .fixedSize(horizontal: false, vertical: true)
              .frame(minWidth: 44, minHeight: 44)
              .contentShape(Rectangle())
          }
          .accessibilityShowsLargeContentViewer()
          .disabled(model.isSaving)
          .accessibilityIdentifier("passageCancel")
        }
        ToolbarItem(placement: .confirmationAction) {
          if model.canManage {
            Button(action: model.save) {
              Text("Save")
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
            }
            .accessibilityShowsLargeContentViewer()
            .disabled(!model.canSave)
            .accessibilityIdentifier("passageSave")
          }
        }
      }
    }
    .interactiveDismissDisabled(model.isSaving)
    .presentationDetents([.large])
  }
}

var annotationInputFixture: Bool {
  #if DEBUG
    ProcessInfo.processInfo.environment["BOOKORBIT_ANNOTATION_INPUT_FIXTURE"] == "1"
  #else
    false
  #endif
}
