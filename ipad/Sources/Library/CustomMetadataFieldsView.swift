import SwiftUI

struct CustomMetadataFieldsView: View {
  @Binding var fields: [CustomMetadataDraft]

  var body: some View {
    LazyVStack(alignment: .leading, spacing: 20) {
      Text("Custom fields").font(.title2).accessibilityAddTraits(.isHeader)
      ForEach($fields) { $field in
        VStack(alignment: .leading, spacing: 8) {
          Text(field.field.label).font(.headline)
          if field.field.type == "boolean" {
            Picker(field.field.label, selection: $field.boolean) {
              Text("Not set").tag("unset")
              Text("Yes").tag("yes")
              Text("No").tag("no")
            }
            .frame(minHeight: 44)
            .accessibilityIdentifier("customMetadata\(field.id)")
          } else {
            TextField(
              field.field.type == "date" ? "YYYY-MM-DD" : "", text: $field.text,
              axis: .vertical
            )
            .textFieldStyle(.roundedBorder)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(field.field.type == "url" ? .URL : .default)
            .frame(minHeight: 44)
            .accessibilityLabel(field.field.label)
            .accessibilityIdentifier("customMetadata\(field.id)")
          }
          Button {
            field.text = ""
            field.boolean = "unset"
          } label: {
            Label("Clear \(field.field.label)", systemImage: "xmark.circle")
              .frame(minHeight: 44)
          }
          .accessibilityIdentifier("customMetadata\(field.id)Clear")
          .disabled(field.value == .null)
          if let message = field.validationMessage {
            Text(message).fixedSize(horizontal: false, vertical: true)
          }
        }
      }
    }
    .foregroundStyle(Color(uiColor: .label))
  }
}
