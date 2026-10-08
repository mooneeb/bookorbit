import SwiftUI
import UIKit

struct BookAddedAtEditorView: View {
  @Bindable var model: BookAddedAtModel
  let saved: (BookAddedAtModel, BookDetail) -> Void
  @Environment(\.dismiss) private var dismiss
  @FocusState private var dateIsFocused: Bool

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          Text("Added date").font(.title2).accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("addedAtEditorHeading")
          Text("This date belongs to the shared book record.")
            .fixedSize(horizontal: false, vertical: true)
          if !model.currentDate.isEmpty {
            Text("Current added date: \(model.currentDate)")
              .fixedSize(horizontal: false, vertical: true)
              .accessibilityIdentifier("addedAtCurrentDate")
          }
          if model.phase == .editing || model.attemptedDate != nil {
            VStack(alignment: .leading, spacing: 12) {
              Text("Date (YYYY-MM-DD)").font(.headline)
              TextField("YYYY-MM-DD", text: $model.selectedDate)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .focused($dateIsFocused)
                .submitLabel(.done)
                .onSubmit { dateIsFocused = false }
                .frame(minHeight: 44)
                .accessibilityLabel("Added date, YYYY-MM-DD")
                .accessibilityIdentifier("addedAtDateInput")
                .disabled(!model.canEdit)
              DatePicker(
                "Choose date",
                selection: Binding(get: { model.pickerDate }, set: model.select),
                in: ...model.pickerMaximum, displayedComponents: .date
              )
              .datePickerStyle(.compact)
              .environment(\.calendar, Calendar(identifier: .iso8601))
              .environment(\.timeZone, BookAddedAtDate.utc)
              .frame(minHeight: 44)
              .disabled(!model.canEdit)
              .accessibilityIdentifier("addedAtDatePicker")
            }
            Text("Dates use your account's time zone: \(model.timeZone.identifier).")
              .fixedSize(horizontal: false, vertical: true)
              .accessibilityIdentifier("addedAtTimeZone")
            if let validation = model.validationMessage, model.canEdit {
              Label(validation, systemImage: "exclamationmark.circle")
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("addedAtValidation")
            }
          }
          if model.isBusy {
            ProgressView(model.phase == .saving ? "Saving added date…" : "Checking added date…")
              .accessibilityIdentifier("addedAtProgress")
          }
          if let message = model.message {
            Label(message, systemImage: "exclamationmark.triangle")
              .fixedSize(horizontal: false, vertical: true)
              .accessibilityIdentifier("addedAtError")
          }
          if model.phase == .failed {
            actionButton("Try again", action: load)
              .accessibilityIdentifier("addedAtLoadRetry")
          }
          if model.canRetry {
            VStack(alignment: .leading, spacing: 12) {
              actionButton("Check saved date", action: check)
                .accessibilityIdentifier("addedAtCheckSaved")
              actionButton("Retry same date", action: save)
                .accessibilityIdentifier("addedAtSaveRetry")
            }
          }
        }
        .padding().frame(maxWidth: .infinity, alignment: .leading)
      }
      .scrollEdgeEffectHidden().clipped()
      .navigationTitle("Edit added date")
      .navigationBarTitleDisplayMode(.inline)
      .safeAreaInset(edge: .bottom) {
        ViewThatFits(in: .horizontal) {
          HStack {
            cancelButton
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
            keyboardButton
          }
        }
        .padding(.horizontal).background(.background)
      }
      .interactiveDismissDisabled(model.phase == .saving)
    }
    .font(.body).foregroundStyle(Color(uiColor: .label))
    .buttonStyle(.borderless)
    .task { await model.prepare() }
    .onDisappear(perform: model.detach)
  }

  private var cancelButton: some View {
    actionButton("Cancel", action: cancel)
      .disabled(model.phase == .saving).accessibilityIdentifier("addedAtCancel")
  }

  private var keyboardButton: some View {
    Button {
      dateIsFocused = false
      UIApplication.shared.sendAction(
        #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    } label: {
      Label("Hide keyboard", systemImage: "keyboard.chevron.compact.down")
        .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
    }
    .accessibilityIdentifier("addedAtHideKeyboard")
  }

  private var saveButton: some View {
    actionButton("Save", action: save)
      .disabled(!model.canSave).accessibilityIdentifier("addedAtSave")
  }

  private func actionButton(_ title: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(title).frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
    }
  }

  private func load() { Task { await model.prepare() } }

  private func save() {
    dateIsFocused = false
    Task {
      await model.save()
      await finishIfSaved()
    }
  }

  private func check() {
    Task {
      await model.checkSavedDate()
      await finishIfSaved()
    }
  }

  private func finishIfSaved() async {
    guard await model.belongsToCurrentSession(), model.phase == .saved, let book = model.book else {
      return
    }
    saved(model, book)
    dismiss()
  }

  private func cancel() {
    model.detach()
    dismiss()
  }
}
