import SwiftUI

struct KoboBookDeliveryView: View {
  let api: BookOrbitAPI
  let user: AuthUser
  let bookID: Int
  let bookTitle: String
  @State private var collections: CollectionModel
  @State private var state: BookKoboState?
  @State private var isBusy = false
  @State private var error: String?
  @State private var notice: String?
  @Environment(\.dismiss) private var dismiss

  init(api: BookOrbitAPI, user: AuthUser, bookID: Int, bookTitle: String) {
    self.api = api
    self.user = user
    self.bookID = bookID
    self.bookTitle = bookTitle
    _collections = State(initialValue: CollectionModel(api: api, ownedOnly: true, bookID: bookID))
  }

  var body: some View {
    NavigationStack {
      List {
        Section {
          Text(bookTitle).font(.headline)
          Text(
            "Choose an owned collection. This book will join that collection and the collection will be subscribed to Kobo. Sync your Kobo to download it."
          )
        }
        if user.hasPermission(.koboSync) {
          if let notice { Text(notice).accessibilityIdentifier("koboBookDeliveryNotice") }
          if let message = error ?? collections.error {
            Section("Could not prepare Kobo delivery") {
              Text(message).accessibilityIdentifier("koboBookDeliveryError")
              Button("Try again", action: reload)
            }
          }
          if let state {
            Section("Current Kobo state") {
              Text(
                state.eligibleForKoboSync
                  ? "Available on next device sync" : "No subscribed collection includes this book"
              )
              .accessibilityIdentifier("koboBookEligibility")
              ForEach(state.syncCollections, id: \.self) { Text($0) }
              ForEach(state.snapshots, id: \.deviceId) { snapshot in
                LabeledContent(
                  snapshot.deviceName,
                  value: snapshot.removedByDevice == true
                    ? "Removed on device"
                    : snapshot.synced == true ? "Catalog update received" : "Catalog update pending"
                )
              }
              if let progress = state.readingState?.progressPercent {
                LabeledContent("Kobo reading progress", value: "\(progress.formatted())%")
              }
              Button("Refresh device state", action: reload).accessibilityIdentifier(
                "koboRefreshBookState")
              NavigationLink("Sync and delivery history") { KoboHistoryView(api: api) }
            }
          }
          Section("Deliver using a collection") {
            if collections.items.isEmpty, !collections.isBusy {
              Text("Create an owned collection in Collections, then return here.")
            }
            ForEach(collections.items) { collection in
              Button {
                deliver(collection)
              } label: {
                VStack(alignment: .leading) {
                  Text(collection.name)
                  Text(collection.syncToKobo ? "Subscribed to Kobo" : "Subscribe and add book")
                    .font(.caption).foregroundStyle(.secondary)
                }
              }.accessibilityIdentifier("koboDeliverCollection\(collection.id)")
            }
            HStack {
              Button("Previous", action: previous).disabled(!collections.canGoBack)
              Spacer()
              Button("Next", action: next).disabled(!collections.canGoNext)
            }
          }
        } else {
          Text("Your account does not have permission to deliver to Kobo.")
        }
      }
      .accessibilityIdentifier("koboBookDeliveryContent")
      .disabled(isBusy || collections.isBusy)
      .searchable(text: $collections.search, prompt: "Search owned collections")
      .onSubmit(of: .search, reload)
      .navigationTitle("Deliver to Kobo")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done", action: dismiss.callAsFunction)
        }
      }
      .task { if user.hasPermission(.koboSync) { await load() } }
    }
  }

  private func reload() { Task { await load() } }
  private func previous() { Task { await collections.previousPage() } }
  private func next() { Task { await collections.nextPage() } }
  private func load() async {
    guard !isBusy else { return }
    isBusy = true
    error = nil
    defer { isBusy = false }
    await collections.load()
    do { state = try await api.koboBookState(bookID) } catch {
      self.error = error.localizedDescription
    }
  }
  private func deliver(_ collection: BookCollection) {
    Task {
      guard !isBusy else { return }
      isBusy = true
      error = nil
      notice = nil
      defer { isBusy = false }
      do {
        _ = try await collections.addBook(bookID, to: collection)
        let _: BookCollection = try await api.boundedJSON(
          "collections/\(collection.id)", method: "PATCH",
          body: JSONEncoder().encode(UpdateCollectionPayload(syncToKobo: true)),
          byteLimit: 32 * 1024)
        state = try await api.koboBookState(bookID)
        await collections.refresh()
        notice =
          "Prepared for Kobo sync using \(collection.name). Sync your device, then refresh delivery history to verify the download."
      } catch { self.error = error.localizedDescription }
    }
  }
}
