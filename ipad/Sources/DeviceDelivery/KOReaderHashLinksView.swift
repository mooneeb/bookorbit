import SwiftUI

private struct KOReaderLinkSelection: Identifiable {
  let id = UUID()
  let hash: String
  let existing: Bool
}

struct KOReaderHashLinksView: View {
  @Bindable var model: KOReaderManagementModel
  @State private var selection: KOReaderLinkSelection?
  @State private var dismissHash: String?
  @State private var unlinkHash: String?
  @State private var dismissAll = false

  var body: some View {
    Form {
      KOReaderFeedbackView(model: model)
      Section("Unmatched books") {
        Text(
          "The server shows up to 100 recent unmatched books. Link a recognized file to the corresponding book in your library, or dismiss it."
        )
        .font(.footnote).foregroundStyle(.secondary)
        if model.unmatched.isEmpty { Text("No unmatched books.").foregroundStyle(.secondary) }
        ForEach(model.visibleUnmatched, id: \.hash) { item in
          VStack(alignment: .leading, spacing: 8) {
            Text(item.title ?? "Unknown title").font(.headline)
            if let authors = item.authors { Text(authors).foregroundStyle(.secondary) }
            Text(item.hash).font(.caption).textSelection(.enabled)
            Text("Last seen: \(item.lastSeenAt)").font(.caption).foregroundStyle(.secondary)
            Button("Link to a library book") {
              selection = KOReaderLinkSelection(hash: item.hash, existing: false)
            }
            .accessibilityIdentifier("koreaderLinkUnmatched\(item.hash)")
            Button("Dismiss unmatched book", role: .destructive) { dismissHash = item.hash }
              .accessibilityIdentifier("koreaderDismissUnmatched\(item.hash)")
          }
        }
        KOReaderListPager(
          page: $model.unmatchedPage, count: model.unmatched.count, size: model.pageSize)
        if !model.unmatched.isEmpty {
          Button("Dismiss all unmatched books", role: .destructive, action: confirmDismissAll)
            .accessibilityIdentifier("koreaderDismissAllUnmatched")
        }
      }
      Section("Manual links") {
        Text(
          "The server shows up to 100 recent manual links. A link associates the KOReader file hash with a library file for sync."
        )
        .font(.footnote).foregroundStyle(.secondary)
        if model.links.isEmpty { Text("No manual links.").foregroundStyle(.secondary) }
        ForEach(model.visibleLinks, id: \.hash) { item in
          VStack(alignment: .leading, spacing: 8) {
            Text(item.bookTitle ?? "Untitled library book").font(.headline)
            Text(item.bookAuthors.joined(separator: ", ")).foregroundStyle(.secondary)
            if let title = item.koreaderTitle { LabeledContent("KOReader title", value: title) }
            Text(item.hash).font(.caption).textSelection(.enabled)
            Button("Change linked book") {
              selection = KOReaderLinkSelection(hash: item.hash, existing: true)
            }
            .accessibilityIdentifier("koreaderRelinkHash\(item.hash)")
            Button("Remove manual link", role: .destructive) { unlinkHash = item.hash }
              .accessibilityIdentifier("koreaderUnlinkHash\(item.hash)")
          }
        }
        KOReaderListPager(page: $model.linkPage, count: model.links.count, size: model.pageSize)
      }
    }
    .disabled(model.isMutating || model.isBusy || !model.hasCredentials || !model.isPermitted)
    .navigationTitle("Book matching")
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button("Refresh", systemImage: "arrow.clockwise", action: refresh)
          .accessibilityIdentifier("koreaderHashLinksRefresh")
      }
    }
    .sheet(item: $selection) { item in
      KOReaderBookPickerView(
        api: model.api, title: item.existing ? "Change linked book" : "Link KOReader book"
      ) { bookID in
        await model.linkBook(hash: item.hash, bookID: bookID, existing: item.existing)
        return model.error
      }
    }
    .confirmationDialog("Dismiss this unmatched book?", isPresented: pending($dismissHash)) {
      if let hash = dismissHash {
        Button("Dismiss book", role: .destructive) { dismissOne(hash) }
      }
    }
    .confirmationDialog("Remove this manual link?", isPresented: pending($unlinkHash)) {
      if let hash = unlinkHash {
        Button("Remove link", role: .destructive) { unlinkOne(hash) }
      }
    } message: {
      Text("The KOReader file returns to the unmatched list if it is still available.")
    }
    .confirmationDialog("Dismiss all unmatched books?", isPresented: $dismissAll) {
      Button("Dismiss all", role: .destructive, action: dismissEveryBook)
    }
  }

  private func pending(_ hash: Binding<String?>) -> Binding<Bool> {
    Binding(get: { hash.wrappedValue != nil }, set: { if !$0 { hash.wrappedValue = nil } })
  }
  private func refresh() { Task { await model.load() } }
  private func confirmDismissAll() { dismissAll = true }
  private func dismissEveryBook() { Task { await model.dismissAll() } }
  private func dismissOne(_ hash: String) {
    dismissHash = nil
    Task { await model.dismissBook(hash) }
  }
  private func unlinkOne(_ hash: String) {
    unlinkHash = nil
    Task { await model.unlinkBook(hash) }
  }
}
