import Foundation

extension CustomMetadataPrimitiveValue {
  var displayText: String {
    switch self {
    case .string(let value): value
    case .number(let value): String(value)
    case .boolean(let value): value ? "Yes" : "No"
    case .null: "Not set"
    }
  }
}

struct CustomMetadataDraft: Identifiable {
  let field: CustomMetadataBookValue
  var text: String
  var boolean: String
  var id: Int { field.fieldId }

  init(field: CustomMetadataBookValue) {
    self.field = field
    switch field.value {
    case .string(let value): text = value
    case .number(let value): text = String(value)
    case .boolean, .null: text = ""
    }
    if case .boolean(let value) = field.value {
      boolean = value ? "yes" : "no"
    } else {
      boolean = "unset"
    }
  }

  var value: CustomMetadataPrimitiveValue {
    if field.type == "boolean" {
      switch boolean {
      case "yes": return .boolean(true)
      case "no": return .boolean(false)
      default: return .null
      }
    }
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.isEmpty { return .null }
    if field.type == "number", let number = Double(value), number.isFinite {
      return .number(number)
    }
    return .string(value)
  }

  var update: CustomMetadataBookValueInput? {
    value == field.value ? nil : CustomMetadataBookValueInput(fieldId: id, value: value)
  }

  var validationMessage: String? {
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return nil }
    switch field.type {
    case "number":
      if Double(value)?.isFinite != true { return "\(field.label) must be a finite number." }
    case "url":
      if let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
        url.host?.isEmpty == false
      {
        return nil
      }
      return "\(field.label) must be a valid http or https URL."
    case "date":
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.calendar = Calendar(identifier: .gregorian)
      formatter.timeZone = TimeZone(secondsFromGMT: 0)
      formatter.dateFormat = "yyyy-MM-dd"
      formatter.isLenient = false
      if value.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil,
        let date = formatter.date(from: value), formatter.string(from: date) == value
      {
        return nil
      }
      return "\(field.label) must be a real date in YYYY-MM-DD format."
    default: break
    }
    return nil
  }
}
