import SwiftUI

struct BookTableCellEditorView: View {
  @Bindable var model: BookTableCellEditorModel
  let saved: () -> Void
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          Text(model.book.title ?? "Untitled book").font(.headline)
          if model.column.id == "readStatus" {
            Picker("Reading status", selection: $model.choice) {
              ForEach(BookReadingVocabulary.statuses, id: \.self) { status in
                Text(BookReadingDraft.label(status)).tag(status)
              }
            }.pickerStyle(.inline).accessibilityIdentifier("tableCellStatus")
          } else if model.column.id == "rating" {
            Picker("Rating", selection: $model.choice) {
              Text("Not rated").tag("unset")
              ForEach(1...5, id: \.self) { rating in Text("\(rating) of 5").tag(String(rating)) }
            }.pickerStyle(.inline).accessibilityIdentifier("tableCellRating")
          } else if model.custom != nil {
            customInput
          } else {
            if model.isNames {
              Text("Enter one name per line. Commas stay part of the name.").font(.footnote)
            }
            MetadataTextInput(
              text: $model.text, label: model.column.label, identifier: "tableCellValue"
            )
            .frame(minHeight: 120)
            if let suggestions = model.suggestions {
              BookTableCellSuggestionsView(
                model: suggestions, query: model.suggestionQuery,
                choose: model.chooseSuggestion)
            }
          }
          if model.column.id == "publishedYear" {
            Text("Changing the year clears the published date.").font(.footnote)
          }
          if model.column.id != "readStatus" {
            Button("Clear value", action: model.clear).frame(minHeight: 44)
              .accessibilityIdentifier("tableCellClear")
          }
          if let message = model.validationMessage {
            Label(message, systemImage: "exclamationmark.circle")
          }
          if let error = model.error {
            Label(error, systemImage: "exclamationmark.triangle")
              .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier(
                "tableCellSaveError")
          }
          if model.isSaving { ProgressView("Saving change…") }
        }.padding().disabled(model.isSaving)
      }
      .navigationTitle("Edit \(model.column.label)")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel", action: dismiss.callAsFunction).disabled(model.isSaving)
            .accessibilityIdentifier("tableCellCancel")
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") {
            Task {
              await model.save()
              if model.isComplete {
                saved()
                dismiss()
              }
            }
          }
          .disabled(model.isSaving || !model.hasChanges || model.validationMessage != nil)
          .accessibilityIdentifier("tableCellSave")
        }
      }
      .interactiveDismissDisabled(model.isSaving)
    }
    .foregroundStyle(.primary)
  }

  @ViewBuilder private var customInput: some View {
    if model.custom?.field.type == "boolean" {
      Picker(
        model.column.label,
        selection: Binding(
          get: { model.custom?.boolean ?? "unset" }, set: { model.custom?.boolean = $0 })
      ) {
        Text("Not set").tag("unset")
        Text("Yes").tag("yes")
        Text("No").tag("no")
      }.pickerStyle(.inline).accessibilityIdentifier("tableCellBoolean")
    } else {
      MetadataTextInput(
        text: Binding(
          get: { model.custom?.text ?? "" }, set: { model.custom?.text = $0 }),
        label: model.column.label, identifier: "tableCellValue"
      )
      .frame(minHeight: 120)
    }
  }
}
