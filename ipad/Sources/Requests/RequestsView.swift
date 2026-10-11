import SwiftUI

struct RequestsView: View {
  @Bindable var session: SessionModel
  @State private var model: BookRequestsModel
  @State private var creating = false
  @Environment(\.dismiss) private var dismiss

  init(session: SessionModel, api: BookOrbitAPI) {
    self.session = session
    _model = State(initialValue: BookRequestsModel(api: api))
  }

  var body: some View {
    NavigationStack {
      List {
        if let error = model.error {
          Section {
            Text(error).foregroundStyle(.red)
            Button("Retry") { Task { await model.load(page: model.page) } }
          }
        }
        Section {
          Picker("Status", selection: $model.status) {
            Text("All statuses").tag("")
            ForEach(
              [
                "pending", "approved", "downloading", "needs_review", "available", "failed",
                "cancelled",
              ], id: \.self
            ) { Text($0.replacingOccurrences(of: "_", with: " ").capitalized).tag($0) }
          }.onChange(of: model.status) { Task { await model.load() } }
          Button("New request") { creating = true }.accessibilityIdentifier("requestNew")
        }
        Section("My requests: \(model.total)") {
          ForEach(model.items, id: \.id) { item in
            Button {
              model.selectedID = item.id
            } label: {
              VStack(alignment: .leading) {
                Text(item.title).font(.headline)
                Text(item.authors.joined(separator: ", ")).font(.subheadline)
                Text(item.status.replacingOccurrences(of: "_", with: " ").capitalized)
              }
            }.accessibilityIdentifier("requestRow\(item.id)")
          }
          if model.items.isEmpty && !model.isBusy { Text("You have no requests in this view.") }
          HStack {
            Button("Previous") { Task { await model.load(page: model.page - 1) } }.disabled(
              model.page <= 1 || model.isBusy)
            Spacer()
            Text("Page \(model.page)")
            Spacer()
            Button("Next") { Task { await model.load(page: model.page + 1) } }.disabled(
              model.page * 20 >= model.total || model.isBusy)
          }
        }
        Section {
          NavigationLink("Request preferences") { RequestPreferencesView(api: model.api) }
            .accessibilityIdentifier("requestPreferences")
        }
        if session.user?.hasPermission(.manageAppSettings) == true {
          Section {
            NavigationLink("Request administration") { RequestAdministrationView(session: session) }
          }
        }
      }
      .accessibilityIdentifier("requestsScreen")
      .navigationTitle("Book requests")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done", action: dismiss.callAsFunction)
        }
      }
      .overlay { if model.isBusy { ProgressView("Loading requests") } }
      .task { await model.load() }
      .refreshable { await model.load(page: model.page) }
      .sheet(isPresented: $creating) { requestForm }
      .navigationDestination(
        isPresented: Binding(
          get: { model.selectedID != nil },
          set: {
            if !$0 {
              model.selectedID = nil
              Task { await model.load(page: model.page) }
            }
          })
      ) {
        if let id = model.selectedID {
          BookRequestDetailView(api: model.api, requestID: id, user: session.user)
        }
      }
    }
  }

  private var requestForm: some View {
    NavigationStack {
      Form {
        Section("Discover or request a book") {
          TextField("Title", text: $model.title).accessibilityIdentifier("requestTitle")
          TextField("Author", text: $model.author).accessibilityIdentifier("requestAuthor")
          TextField("ISBN", text: $model.isbn).accessibilityIdentifier("requestISBN")
          Picker("Medium", selection: $model.medium) {
            Text("Ebook").tag("ebook")
            Text("Audiobook").tag("audiobook")
            Text("Comic").tag("comic")
          }
          Button("Discover metadata", action: model.discover).accessibilityIdentifier(
            "requestDiscover")
          if model.isDiscovering {
            ProgressView("Discovering books")
            Button("Cancel discovery", action: model.stopDiscovery)
          }
          Button("Check availability") { Task { await model.checkAvailability() } }
            .accessibilityIdentifier("requestAvailability")
          if let availability = model.availability {
            if let book = availability.ownedBookId {
              Text("Already in your library: book \(book)")
            } else if let id = availability.existingRequestId {
              Text(
                availability.alreadySubscribed
                  ? "You already follow request \(id)." : "Submitting will join request \(id).")
            } else {
              Text("No matching book or active request found.")
            }
          }
          ForEach(model.providerStatuses.keys.sorted(), id: \.self) {
            Text("\($0): \(model.providerStatuses[$0] ?? "")")
          }
          ForEach(model.matches) { match in
            Button {
              model.choose(match)
            } label: {
              VStack(alignment: .leading) {
                Text(match.candidate.title ?? "Untitled")
                Text(match.candidate.authors?.joined(separator: ", ") ?? "")
              }
            }
            .accessibilityIdentifier("requestMetadata\(match.candidate.providerId)")
          }
        }
        Section("Delivery") {
          Picker("Destination library", selection: $model.libraryID) {
            Text("Server default").tag(0)
            ForEach(model.libraries) { Text($0.name).tag($0.id) }
          }.accessibilityIdentifier("requestDestination")
          if session.user?.hasPermission(.bookRequestSelfFulfill) == true {
            Toggle("Fulfil this request myself", isOn: $model.selfServe).accessibilityIdentifier(
              "requestSelfServe")
          }
          Text("The server selects the destination folder and checks your library access.").font(
            .footnote)
        }
        if let error = model.error {
          Section { Text(error).accessibilityIdentifier("requestError") }
        }
        Button("Create or join request") {
          Task {
            await model.submit()
            if model.selectedID != nil { creating = false }
          }
        }
        .disabled(
          model.isBusy || model.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
        .accessibilityIdentifier("requestCreate")
      }
      .navigationTitle("Request a book")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Close") {
            model.stopDiscovery()
            creating = false
          }
        }
      }
      .task { await model.loadDestinations() }
      .onDisappear(perform: model.stopDiscovery)
    }
  }
}
