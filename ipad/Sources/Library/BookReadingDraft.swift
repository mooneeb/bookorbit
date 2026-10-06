import Foundation
import Observation

@MainActor @Observable
final class BookReadingDraft {
  var status: String
  var started: String
  var finished: String
  var note: String
  private var originalStatus: String
  private var originalStarted: String
  private var originalFinished: String
  private var originalNote: String
  let timeZone: TimeZone

  init(book: BookDetail, timeZone: TimeZone) {
    self.timeZone = timeZone
    let status = book.readStatus?.status ?? "unread"
    let started = ReadingDate.key(book.readStatus?.startedAt, timeZone: timeZone)
    let finished = ReadingDate.key(book.readStatus?.finishedAt, timeZone: timeZone)
    let note = book.personalNote ?? ""
    self.status = status
    self.started = started
    self.finished = finished
    self.note = note
    originalStatus = status
    originalStarted = started
    originalFinished = finished
    originalNote = Self.normalized(note)
  }

  var noteChanged: Bool { Self.normalized(note) != originalNote }
  var hasChanges: Bool { statusPayload != nil || noteChanged }

  var statusPayload: SetBookReadingStatusPayload? {
    let started = started.trimmingCharacters(in: .whitespacesAndNewlines)
    let finished = finished.trimmingCharacters(in: .whitespacesAndNewlines)
    guard status != originalStatus || started != originalStarted || finished != originalFinished
    else { return nil }
    return .init(
      status: status != originalStatus ? status : nil,
      startedAt: updateDate(started, original: originalStarted),
      finishedAt: updateDate(finished, original: originalFinished))
  }

  var notePayload: UpdateBookPersonalNotePayload {
    let value = Self.normalized(note)
    return .init(note: value.isEmpty ? .clear : .set(value))
  }

  var validationError: String? {
    guard BookReadingVocabulary.statuses.contains(status) else { return "Choose a reading status." }
    let today = ReadingDate.format(Date(), timeZone: timeZone)
    let started = started.trimmingCharacters(in: .whitespacesAndNewlines)
    let finished = finished.trimmingCharacters(in: .whitespacesAndNewlines)
    for (label, value) in [("Started", started), ("Finished", finished)] where !value.isEmpty {
      guard ReadingDate.isValid(value) else {
        return "\(label) must be a real date in YYYY-MM-DD format."
      }
      guard value <= today else {
        return "\(label) cannot be in the future in your account's time zone."
      }
    }
    if !started.isEmpty, !finished.isEmpty, finished < started {
      return "Finished cannot be before Started."
    }
    if ["unread", "want_to_read"].contains(status), !started.isEmpty || !finished.isEmpty {
      return
        "Unread and Want to read do not have reading dates. Clear the dates or choose another status."
    }
    if status != originalStatus, ["reading", "rereading", "on_hold"].contains(status),
      !finished.isEmpty
    {
      return
        "An active reading status cannot have a finished date. Clear Finished or choose a completed status."
    }
    if Self.normalized(note).utf16.count > BookReadingVocabulary.noteMaximum {
      return "Your note must be no longer than \(BookReadingVocabulary.noteMaximum) characters."
    }
    return nil
  }

  func statusChanged() {
    if ["unread", "want_to_read"].contains(status) {
      started = ""
      finished = ""
    } else if ["reading", "rereading", "on_hold"].contains(status) {
      finished = ""
    }
  }

  func acknowledgeStatus(_ value: UserBookStatus) {
    status = value.status
    started = ReadingDate.key(value.startedAt, timeZone: timeZone)
    finished = ReadingDate.key(value.finishedAt, timeZone: timeZone)
    originalStatus = status
    originalStarted = started
    originalFinished = finished
  }

  func acknowledgeNote(_ value: String?) {
    note = value ?? ""
    originalNote = Self.normalized(note)
  }

  static func label(_ status: String) -> String {
    switch status {
    case "want_to_read": "Want to read"
    case "on_hold": "On hold"
    case "rereading": "Re-reading"
    default: status.capitalized
    }
  }

  private func updateDate(_ value: String, original: String) -> FieldUpdate<String>? {
    guard value != original else { return nil }
    return value.isEmpty ? .clear : .set(value)
  }

  private static func normalized(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

enum ReadingDate {
  static func key(_ value: String?, timeZone: TimeZone) -> String {
    guard let value else { return "" }
    if isValid(value) { return value }
    let prefix = String(value.prefix(10))
    if value.range(
      of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}T00:00:00(?:\\.0+)?Z$", options: .regularExpression) != nil,
      isValid(prefix)
    {
      return prefix
    }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) { return format(date, timeZone: timeZone) }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value).map { format($0, timeZone: timeZone) } ?? ""
  }

  static func isValid(_ value: String) -> Bool {
    guard value.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil else {
      return false
    }
    let formatter = formatter(timeZone: TimeZone(secondsFromGMT: 0)!)
    guard let date = formatter.date(from: value) else { return false }
    return formatter.string(from: date) == value
  }

  static func format(_ date: Date, timeZone: TimeZone) -> String {
    formatter(timeZone: timeZone).string(from: date)
  }

  private static func formatter(timeZone: TimeZone) -> DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = timeZone
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.isLenient = false
    return formatter
  }
}
