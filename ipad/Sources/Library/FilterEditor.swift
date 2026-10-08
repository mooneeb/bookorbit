import SwiftUI

struct FilterEditor: View {
  @Binding var draft: FilterDraft
  var depth = 1

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if draft.isGroup {
        Picker(selection: $draft.join) {
          Text("All conditions").tag("AND")
          Text("Any condition").tag("OR")
        } label: {
          Text("Match conditions").font(.body)
        }
        .font(.body)
        ForEach($draft.children) { child in
          VStack(alignment: .leading, spacing: 8) {
            AnyView(FilterEditor(draft: child, depth: depth + 1))
            Button("Remove condition", role: .destructive) {
              draft.children.removeAll { $0.id == child.wrappedValue.id }
            }
            .font(.body).frame(minHeight: 44)
          }.padding().background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        }
        Button("Add condition") { draft.children.append(FilterDraft()) }
          .font(.body).frame(minHeight: 44).disabled(draft.nodeCount >= 65)
          .accessibilityIdentifier("addFilterCondition")
        if depth < 5 {
          Button("Add condition group") { draft.children.append(.group()) }
            .font(.body).frame(minHeight: 44).disabled(draft.nodeCount >= 65)
        }
      } else {
        Picker("Field", selection: $draft.field) {
          ForEach(FilterVocabulary.operators.keys.sorted(), id: \.self) { field in
            Text(queryFieldLabel(field)).tag(field)
          }
          if FilterVocabulary.operators[draft.field] == nil { Text(draft.field).tag(draft.field) }
        }.onChange(of: draft.field) { draft.changeField() }
        Picker("Condition", selection: $draft.operation) {
          ForEach(draft.operators, id: \.self) { operation in
            Text(queryFieldLabel(operation)).tag(operation)
          }
          if !draft.operators.contains(draft.operation) {
            Text(queryFieldLabel(draft.operation)).tag(draft.operation)
          }
        }.onChange(of: draft.operation) { draft.changeOperation() }
        if ["communityRating", "communityRatingCount"].contains(draft.field) {
          Picker(
            "Rating provider",
            selection: Binding(
              get: { draft.provider ?? "any" }, set: { draft.provider = $0 == "any" ? nil : $0 })
          ) {
            ForEach(FilterVocabulary.ratingProviders, id: \.self) { provider in
              Text(queryFieldLabel(provider)).tag(provider)
            }
          }
        }
        if draft.needsValue {
          if draft.field == "readStatus" || draft.field == "format" {
            ForEach(
              draft.field == "readStatus"
                ? FilterVocabulary.readStatuses : FilterVocabulary.formats, id: \.self
            ) { choice in
              Toggle(
                draft.field == "format"
                  ? choice.uppercased()
                  : choice.replacingOccurrences(of: "_", with: " ").capitalized,
                isOn: Binding(
                  get: { draft.value.components(separatedBy: .newlines).contains(choice) },
                  set: { enabled in
                    var values = draft.value.components(separatedBy: .newlines).filter {
                      !$0.isEmpty && $0 != choice
                    }
                    if enabled { values.append(choice) }
                    draft.value = values.joined(separator: "\n")
                    draft.valueKind = .texts
                  }))
            }
          } else {
            Picker("Value type", selection: $draft.valueKind) {
              ForEach(FilterValueKind.allCases) { kind in Text(kind.rawValue).tag(kind) }
            }
            TextField("Value", text: $draft.value, axis: .vertical)
              .textInputAutocapitalization(.never).autocorrectionDisabled()
              .accessibilityIdentifier("filterValue")
          }
          if draft.valueKind == .texts || draft.valueKind == .numbers {
            Text("Enter one value per line.").font(.body)
          }
          if draft.operation == "between" { TextField("Through value", text: $draft.valueTo) }
          if ["before", "after", "between"].contains(draft.operation),
            ["addedAt", "startedAt", "finishedAt", "publishedDate"].contains(draft.field)
          {
            Text("Use dates in YYYY-MM-DD format.").font(.body)
          }
        }
      }
    }.foregroundStyle(Color(uiColor: .label))
  }
}
