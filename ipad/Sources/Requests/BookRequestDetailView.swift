import Observation
import SwiftUI

@MainActor @Observable
final class BookRequestDetailModel {
  let api: BookOrbitAPI
  let id: Int
  var item: BookRequestItem?
  var releases: ReleaseSearchResult?
  var clients: [DownloadClientSummary] = []
  var clientID = 0
  var review: BookRequestReview?
  var error: String?
  var isBusy = false
  var left = false

  init(api: BookOrbitAPI, id: Int) {
    self.api = api
    self.id = id
  }

  func refresh() async {
    await perform { self.item = try await self.api.request(self.id) }
  }

  func search() async {
    await perform {
      self.releases = try await self.api.requestReleases(self.id)
      self.clients = try await self.api.send("book-request-fulfilment/download-clients")
    }
  }

  func grab(_ release: ReleaseCandidateItem) async {
    await perform {
      _ = try await self.api.grabRequest(
        self.id,
        body: GrabBookRequestPayload(
          indexerId: release.indexerId, releaseGuid: release.guid, magnet: nil,
          torrentFileBase64: nil, torrentFileName: nil,
          downloadClientId: self.clientID > 0 ? self.clientID : nil))
      self.item = try await self.api.request(self.id)
    }
  }

  func cancel(downloadID: Int? = nil) async {
    await perform { self.item = try await self.api.cancelRequest(self.id, downloadID: downloadID) }
  }

  func unsubscribe() async {
    await perform {
      try await self.api.unsubscribeRequest(self.id)
      self.left = true
    }
  }

  func loadReview() async {
    await perform { self.review = try await self.api.requestReview(self.id) }
  }

  func resolveReview(discard: Bool) async {
    await perform {
      self.item = try await self.api.resolveRequestReview(self.id, discard: discard)
      self.review = nil
    }
  }

  private func perform(_ work: () async throws -> Void) async {
    guard !isBusy else { return }
    isBusy = true
    error = nil
    defer { isBusy = false }
    do { try await work() } catch { self.error = error.localizedDescription }
  }
}

struct BookRequestDetailView: View {
  @State private var model: BookRequestDetailModel
  let user: AuthUser?
  @State private var confirmsCancel = false
  @State private var confirmsFile = false
  @State private var reading = false
  @Environment(\.dismiss) private var dismiss

  init(api: BookOrbitAPI, requestID: Int, user: AuthUser?) {
    _model = State(initialValue: BookRequestDetailModel(api: api, id: requestID))
    self.user = user
  }

  private var canDrive: Bool {
    guard let item = model.item, let user else { return false }
    return item.userId == user.id || item.fulfillerUserId == user.id
      || user.hasPermission(.manageBookRequests)
  }
  private var canFulfil: Bool {
    guard let item = model.item, let user else { return false }
    return user.hasPermission(.bookRequestSelfFulfill)
      && (item.fulfillerUserId ?? item.userId) == user.id
  }

  var body: some View {
    List {
      if let item = model.item {
        Section {
          Text(item.title).font(.title2)
          Text(item.authors.joined(separator: ", "))
          Text(item.status.replacingOccurrences(of: "_", with: " ").capitalized)
            .accessibilityIdentifier("requestStatus")
          if let reason = item.statusReason {
            Text(reason).fixedSize(horizontal: false, vertical: true)
          }
          if let library = item.targetLibraryName { Text("Destination: \(library)") }
          Text("Requested by \(item.requesterName)")
          Text("\(item.subscribers.count) followers")
        }
        if let bookID = item.matchedBookId, user?.hasPermission(.libraryDownload) == true {
          Section {
            Button("Read received book") { reading = true }.accessibilityIdentifier("requestRead")
          }
          .sheet(isPresented: $reading) {
            BookDetailView(
              api: model.api, bookID: bookID,
              canEditMetadata: user?.hasPermission(.libraryEditMetadata) == true, canRead: true,
              userID: user?.id ?? 0)
          }
        }
        if let download = item.download {
          Section("Download") {
            Text(download.releaseTitle)
            ProgressView(value: download.progressPercent, total: 100)
            Text("\(Int(download.progressPercent))%: \(download.status)")
            if let error = download.errorMessage { Text(error) }
            if canDrive && ["grabbed", "downloading"].contains(download.status) {
              Button("Stop download and choose another release", role: .destructive) {
                Task { await model.cancel(downloadID: download.id) }
              }.accessibilityIdentifier("requestCancelDownload")
            }
            ForEach(download.releaseUnits ?? [], id: \.index) { unit in
              Button("Import \(unit.title ?? "book \(unit.index + 1)")") {
                Task { await selectUnit(downloadID: download.id, index: unit.index) }
              }.disabled(!canFulfil)
            }
          }
        }
        if canFulfil && ["approved", "searching", "failed"].contains(item.status) {
          Section("Choose a release") {
            Button("Search releases") { Task { await model.search() } }.accessibilityIdentifier(
              "requestReleaseSearch")
            if !model.clients.isEmpty {
              Picker("Download client", selection: $model.clientID) {
                Text("Server default").tag(0)
                ForEach(model.clients, id: \.id) { Text($0.name).tag($0.id) }
              }
            }
            if let result = model.releases {
              ForEach(result.indexers, id: \.indexerId) {
                Text("\($0.indexerName): \($0.error ?? "searched")")
              }
              if result.releases.isEmpty {
                Text(
                  result.enabledIndexerCount == 0
                    ? "No enabled sources. Ask an administrator to configure a source."
                    : "No matching releases. Retry or refine the request.")
              }
              ForEach(Array(result.releases.prefix(100).enumerated()), id: \.offset) {
                index, release in
                VStack(alignment: .leading) {
                  Text(release.title).font(.headline)
                  Text("\(release.indexerName): \(release.formats.joined(separator: ", "))")
                  Text("Match score: \(Int(release.score))")
                  Button("Download this release") { Task { await model.grab(release) } }
                    .accessibilityIdentifier("requestGrab\(index)")
                }
              }
            }
          }
        }
        if canFulfil && item.status == "needs_review" {
          Section("Review imported files") {
            Button("Inspect received files") { Task { await model.loadReview() } }
            if let review = model.review {
              ForEach(Array(review.files.enumerated()), id: \.offset) { _, file in
                Text(file.fileName)
              }
              if let verification = review.verification {
                Text("Verification score: \(Int(verification.score))")
              }
              Button("File this book") { confirmsFile = true }.disabled(!review.canFile)
              Button("Discard imported files", role: .destructive) {
                Task { await model.resolveReview(discard: true) }
              }
            }
          }
        }
        if canDrive && !["available", "rejected", "cancelled"].contains(item.status) {
          Section {
            Button("Cancel request", role: .destructive) { confirmsCancel = true }
              .accessibilityIdentifier("requestCancel")
          }
        }
        if let user, item.userId != user.id, (item.fulfillerUserId ?? item.userId) != user.id,
          item.subscribers.contains(where: { $0.userId == user.id })
        {
          Section {
            Button("Unsubscribe") {
              Task {
                await model.unsubscribe()
                if model.left { dismiss() }
              }
            }.accessibilityIdentifier("requestUnsubscribe")
          }
        }
      }
      if let error = model.error {
        Section {
          Text(error).accessibilityIdentifier("requestDetailError")
          Button("Retry refresh") { Task { await model.refresh() } }
        }
      }
    }
    .disabled(model.isBusy)
    .accessibilityIdentifier("requestDetail")
    .navigationTitle("Book request")
    .toolbar { Button("Refresh") { Task { await model.refresh() } } }
    .task(id: model.item?.status) {
      await model.refresh()
      while !Task.isCancelled
        && model.item.map({
          ["grabbed", "downloading", "importing", "searching"].contains($0.status)
        }) == true
      {
        try? await Task.sleep(for: .seconds(3))
        if !Task.isCancelled { await model.refresh() }
      }
    }
    .alert("Cancel this request?", isPresented: $confirmsCancel) {
      Button("Keep request", role: .cancel) {}
      Button("Cancel request", role: .destructive) { Task { await model.cancel() } }
    }
    .alert("File the received book?", isPresented: $confirmsFile) {
      Button("Keep reviewing", role: .cancel) {}
      Button("File book") { Task { await model.resolveReview(discard: false) } }
    } message: {
      Text("This accepts the imported files even when metadata verification did not pass.")
    }
  }

  private func selectUnit(downloadID: Int, index: Int) async {
    do {
      try await model.api.sendEmpty(
        "book-request-fulfilment/\(model.id)/downloads/\(downloadID)/select-unit",
        body: JSONSerialization.data(withJSONObject: ["unitIndex": index]))
      await model.refresh()
    } catch { model.error = error.localizedDescription }
  }
}
