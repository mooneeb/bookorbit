import Foundation

enum BookAddedAtDate {
  static let utc = TimeZone(secondsFromGMT: 0)!

  static func timeZone(_ value: String?) -> TimeZone {
    let name = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return TimeZone(identifier: name) ?? utc
  }

  static func isValid(_ value: String) -> Bool {
    guard value.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil
    else { return false }
    let parts = value.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3, (1...9999).contains(parts[0]), (1...12).contains(parts[1]) else {
      return false
    }
    let year = parts[0]
    let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
    let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    return (1...days[parts[1] - 1]).contains(parts[2])
  }

  static func key(_ value: String, timeZone: TimeZone) -> String? {
    if isValid(value) { return value }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    var date = formatter.date(from: value)
    if date == nil {
      formatter.formatOptions = [.withInternetDateTime]
      date = formatter.date(from: value)
    }
    return date.map { key($0, timeZone: timeZone) }
  }

  static func key(_ date: Date, timeZone: TimeZone) -> String {
    var calendar = Calendar(identifier: .iso8601)
    calendar.timeZone = timeZone
    let parts = calendar.dateComponents([.era, .year, .month, .day], from: date)
    guard parts.era == 1, let year = parts.year, let month = parts.month, let day = parts.day,
      (1...9999).contains(year)
    else { return "" }
    return String(format: "%04d-%02d-%02d", year, month, day)
  }

  static func pickerDate(_ key: String) -> Date? {
    guard isValid(key) else { return nil }
    let parts = key.split(separator: "-").compactMap { Int($0) }
    var calendar = Calendar(identifier: .iso8601)
    calendar.timeZone = utc
    return calendar.date(
      from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
  }
}
