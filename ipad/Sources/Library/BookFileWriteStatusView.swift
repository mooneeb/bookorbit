import SwiftUI

struct BookFileWriteStatusView: View {
  let book: BookDetail

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Automatic file metadata").font(.headline).accessibilityAddTraits(.isHeader)
      if let status = book.fileWriteStatus {
        Text(status.enabled ? "Enabled for configured targets" : "Disabled for this book")
          .accessibilityIdentifier("bookFileWriteConfiguredStatus")
        if status.enabled {
          Text(
            "Writable formats: \(status.writableFormats.map { $0.uppercased() }.joined(separator: ", "))"
          )
          Text("\(status.writableFields.count.formatted()) configured field names can be written.")
          DisclosureGroup("Configured field names") {
            Text(status.writableFields.joined(separator: ", "))
              .accessibilityIdentifier("bookFileWriteConfiguredFields")
          }
        } else {
          Text(disabledReason(status.reason))
            .accessibilityIdentifier("bookFileWriteDisabledReason")
        }
      } else {
        Text("The server did not provide automatic file-write status.")
          .accessibilityIdentifier("bookFileWriteConfiguredStatus")
      }
      Text(
        "This is the configured automatic capability, not evidence that current saved metadata is embedded in every file. Manual write-and-rename can override the automatic enable switches."
      )
      .font(.footnote)
      if let lastWrittenAt = book.lastWrittenAt {
        Text("Last recorded successful metadata write: \(dateLabel(lastWrittenAt))")
          .accessibilityIdentifier("bookFileWriteLastRecorded")
      } else {
        Text("No successful metadata write time is recorded.")
          .accessibilityIdentifier("bookFileWriteLastRecorded")
      }
    }
    .fixedSize(horizontal: false, vertical: true)
    .accessibilityIdentifier("bookFileWriteStatus")
  }

  private func dateLabel(_ value: String) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    var date = formatter.date(from: value)
    if date == nil {
      formatter.formatOptions = [.withInternetDateTime]
      date = formatter.date(from: value)
    }
    return date?.formatted(date: .abbreviated, time: .shortened) ?? value
  }

  private func disabledReason(_ reason: String?) -> String {
    switch reason {
    case "library_disabled": "Automatic metadata writing is disabled in this library."
    case "no_primary_file": "This book has no primary file for metadata writing."
    case "format_not_supported": "The target format does not support metadata writing."
    case "format_disabled": "Metadata writing is disabled for the target format."
    case "file_exceeds_size_limit": "The target file exceeds the configured write size limit."
    default: "The server did not provide a reason."
    }
  }
}

struct BookWriteAndRenameResultView: View {
  let result: BookWriteAndRenameResult

  private var summary: String {
    let writeSucceeded = result.write.status == "success"
    let renameSucceeded = result.rename.status == "success"
    let renameUnchanged =
      result.rename.status == "skipped" && result.rename.reason == "path unchanged"
    if writeSucceeded && (renameSucceeded || renameUnchanged) { return "Both stages acknowledged" }
    if writeSucceeded || renameSucceeded || !result.write.fieldsWritten.isEmpty {
      return "Partial outcome acknowledged"
    }
    return "Operation acknowledged with no completed stage"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(summary).font(.headline).accessibilityIdentifier("bookFileWriteResultSummary")
      Text("Metadata write: \(label(result.write.status))")
        .accessibilityIdentifier("bookFileWriteOutcome")
      if let reason = result.write.reason {
        Text(reason).accessibilityIdentifier("bookFileWriteReason")
      }
      Text(
        "\(result.write.fieldsWritten.count.formatted()) field names reported written across targets."
      )
      .accessibilityIdentifier("bookFileWriteFieldCount")
      if !result.write.fieldsWritten.isEmpty {
        DisclosureGroup("Reported written field names") {
          Text(result.write.fieldsWritten.prefix(64).joined(separator: ", "))
          if result.write.fieldsWritten.count > 64 {
            Text(
              "\((result.write.fieldsWritten.count - 64).formatted()) more field names reported.")
          }
        }
      }
      Text(
        "The metadata result aggregates the server's targets. Some targets can be skipped even when it reports success; a failed result can include fields written before a failure."
      )
      .font(.footnote)
      Divider()
      Text("Rename: \(label(result.rename.status))")
        .accessibilityIdentifier("bookFileRenameOutcome")
      if let reason = result.rename.reason {
        Text(reason).accessibilityIdentifier("bookFileRenameReason")
      }
      if let oldPath = result.rename.oldPath {
        Text("Previous server path: \(oldPath)")
          .textSelection(.enabled).accessibilityIdentifier("bookFileRenameOldPath")
      }
      if let newPath = result.rename.newPath {
        Text("Resulting server path: \(newPath)")
          .textSelection(.enabled).accessibilityIdentifier("bookFileRenameNewPath")
      }
      Text(
        "Automatic metadata writing: \(result.libraryAutoWriteEnabled ? "enabled" : "disabled"). Automatic renaming: \(result.libraryAutoRenameEnabled ? "enabled" : "disabled"). These switches do not prevent this manual operation."
      )
      .font(.footnote).accessibilityIdentifier("bookFileWriteAutomaticFlags")
    }
    .fixedSize(horizontal: false, vertical: true)
    .accessibilityIdentifier("bookFileWriteResult")
  }

  private func label(_ status: String) -> String {
    switch status {
    case "success": "server reported success"
    case "skipped": "skipped"
    case "failed": "failed"
    default: "unknown"
    }
  }
}
