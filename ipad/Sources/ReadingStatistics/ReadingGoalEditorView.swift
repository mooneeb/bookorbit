import SwiftUI

struct ReadingGoalEditorView: View {
  @Bindable var model: ReadingStatisticsModel
  @Environment(\.dismiss) private var dismiss
  @State private var books: String

  init(model: ReadingStatisticsModel) {
    self.model = model
    _books = State(initialValue: String(Int(model.activity?.goal.goalBooks ?? 12)))
  }

  private var goal: Int? { Int(books.trimmingCharacters(in: .whitespacesAndNewlines)) }
  private var valid: Bool { goal.map { (1...10_000).contains($0) } ?? false }

  var body: some View {
    NavigationStack {
      Form {
        Section("Books to finish this year") {
          TextField("Number of books", text: $books)
            .keyboardType(.numberPad)
            .accessibilityIdentifier("readingGoalBooks")
          Text(
            "Choose a whole number from 1 to 10,000. The goal is shared with your web dashboard."
          )
          .font(.footnote)
          if !valid {
            Label(
              "Choose a whole number of books from 1 to 10,000.",
              systemImage: "exclamationmark.triangle")
          }
        }
        if let error = model.goalError {
          Section {
            Text(error).accessibilityIdentifier("readingGoalError")
            Button("Retry saving goal", action: save).disabled(!valid)
          }
        }
        if model.activity?.goal.goalBooks != nil {
          Section { Button("Remove reading goal", role: .destructive, action: remove) }
        }
        if model.isSavingGoal { ProgressView("Saving reading goal…") }
      }
      .disabled(model.isSavingGoal)
      .navigationTitle("Reading goal")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel", action: dismiss.callAsFunction).disabled(model.isSavingGoal)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save", action: save).disabled(!valid || model.isSavingGoal)
            .accessibilityIdentifier("saveReadingGoal")
        }
      }
      .interactiveDismissDisabled(model.isSavingGoal)
    }
  }

  private func save() {
    guard valid, let goal else { return }
    Task { if await model.saveGoal(goal) { dismiss() } }
  }
  private func remove() { Task { if await model.saveGoal(nil) { dismiss() } } }
}
