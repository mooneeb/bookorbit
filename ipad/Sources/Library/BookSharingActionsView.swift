import SwiftUI

struct BookSharingActionsView: View {
  let api: BookOrbitAPI
  let book: BookDetail
  let userID: Int
  @Binding var selection: Selection?
  @State private var user: AuthUser?
  @State private var userNamespace: String?
  @State private var isLoadingUser = true
  @State private var emailPreparation: Task<Void, Never>?
  @State private var emailPreparationID: UUID?
  @State private var requestedEmail: Destination?
  @State private var emailPreparationError: String?

  var body: some View {
    Section {
      if let user, user.id == userID, permitsSharing(user) {
        actions(user)
          .disabled(emailPreparationID != nil)
        if emailPreparationID != nil {
          ProgressView(String(localized: "Preparing email delivery"))
          Button(String(localized: "Cancel"), action: cancelEmailPreparation)
            .accessibilityIdentifier("cancelEmailPreparation")
        }
        if let emailPreparationError {
          Text(emailPreparationError).accessibilityIdentifier("emailPreparationError")
          Button(String(localized: "Try again"), action: retryEmailPreparation)
            .accessibilityIdentifier("retryEmailPreparation")
        }
      } else if isLoadingUser {
        ProgressView(String(localized: "Loading sharing permissions"))
      } else {
        Text(String(localized: "Sharing is unavailable for this account."))
      }
    } header: {
      Text(String(localized: "Share and deliver"))
        .task(id: "\(ObjectIdentifier(api)):\(userID)") {
          guard userID > 0,
            let authenticated = try? await api.authenticatedUser(), authenticated.id == userID,
            let namespace = try? await api.imageNamespace()
          else {
            cancelEmailPreparation()
            user = nil
            userNamespace = nil
            selection = nil
            isLoadingUser = false
            return
          }
          guard user != authenticated || userNamespace != namespace else { return }
          cancelEmailPreparation()
          selection = nil
          user = authenticated
          userNamespace = namespace
          isLoadingUser = false
        }
    }
    .onChange(of: book.id) { discardEmailPreparation() }
    .onChange(of: userID) { discardEmailPreparation() }
    .onChange(of: ObjectIdentifier(api)) { discardEmailPreparation() }
  }

  @ViewBuilder static func destinationView(
    api: BookOrbitAPI, book: BookDetail, selection: Selection
  ) -> some View {
    let user = selection.user
    switch selection.destination {
    case .kobo:
      KoboBookDeliveryView(
        api: api, user: user, bookID: book.id, bookTitle: book.title ?? "Book")
    case .catalog:
      CatalogSettingsView(api: api, user: user, book: book)
    case .email(let fileID):
      EmailBookDeliveryView(
        api: api, user: user, bookID: book.id, bookTitle: book.title ?? "Book",
        files: book.files, initialFileID: fileID, preparedModel: selection.emailModel)
    case .hardcover:
      NativeDismissibleFeatureView(identifier: "hardcoverBookDone") {
        HardcoverBookView(api: api, bookID: book.id, title: book.title ?? "Book")
      }
    case .storygraph:
      NativeDismissibleFeatureView(identifier: "storygraphBookDone") {
        StoryGraphBookView(api: api, bookID: book.id, title: book.title ?? "Book")
      }
    }
  }

  private func permitsSharing(_ user: AuthUser) -> Bool {
    let permissions: [Permission] = [
      .koboSync, .koreaderSync, .opdsAccess, .emailSend, .hardcoverSync, .storygraphSync,
    ]
    return permissions.contains { user.hasPermission($0) }
  }

  @ViewBuilder private func actions(_ user: AuthUser) -> some View {
    if user.hasPermission(.koboSync) {
      Button(String(localized: "Send to Kobo")) { select(.kobo, user: user) }
        .frame(minHeight: 44).accessibilityIdentifier("deliverToKobo")
    }
    if user.hasPermission(.koreaderSync) || user.hasPermission(.opdsAccess) {
      Button(String(localized: "Deliver through KOReader or OPDS")) { select(.catalog, user: user) }
        .frame(minHeight: 44).accessibilityIdentifier("catalogBookDelivery")
    }
    if user.hasPermission(.emailSend), !book.files.isEmpty {
      Button(String(localized: "Send by email or Kindle")) { select(.email(nil), user: user) }
        .frame(minHeight: 44).accessibilityIdentifier("sendBookByEmail")
      ForEach(book.files) { file in
        Button {
          select(.email(file.id), user: user)
        } label: {
          Text(String(localized: "Email file: \(file.filename ?? file.format ?? "Book file")"))
            .fixedSize(horizontal: false, vertical: true).frame(minHeight: 44)
        }.accessibilityIdentifier("emailBookFile\(file.id)")
      }
    }
    if user.hasPermission(.hardcoverSync) {
      Button(String(localized: "Hardcover reading record")) { select(.hardcover, user: user) }
        .frame(minHeight: 44).accessibilityIdentifier("hardcoverBook\(book.id)")
    }
    if user.hasPermission(.storygraphSync) {
      Button(String(localized: "StoryGraph reading record")) { select(.storygraph, user: user) }
        .frame(minHeight: 44).accessibilityIdentifier("storygraphBook\(book.id)")
    }
  }

  private func select(_ destination: Destination, user: AuthUser) {
    guard user.id == userID else { return }
    if case .email(let requestedFileID) = destination {
      guard user.hasPermission(.emailSend), emailPreparationID == nil,
        let namespace = userNamespace
      else { return }
      let files = EmailBookDeliveryView.supportedFiles(book.files)
      let fileID = files.first(where: { $0.id == requestedFileID })?.id ?? files.first?.id ?? 0
      let model = EmailBookDeliveryModel(api: api, user: user, bookID: book.id, fileID: fileID)
      let attempt = UUID()
      emailPreparationID = attempt
      requestedEmail = destination
      emailPreparationError = nil
      emailPreparation = Task {
        await model.load()
        guard !Task.isCancelled, emailPreparationID == attempt else { return }
        let authenticated = try? await api.authenticatedUser()
        let currentNamespace = try? await api.imageNamespace()
        guard !Task.isCancelled, emailPreparationID == attempt else { return }
        emailPreparationID = nil
        emailPreparation = nil
        guard authenticated == user, currentNamespace == namespace else { return }
        guard model.loaded else {
          emailPreparationError = model.error ?? "Could not prepare email delivery."
          return
        }
        selection = Selection(
          user: user, bookID: book.id, destination: destination, emailModel: model)
      }
    } else {
      selection = Selection(user: user, bookID: book.id, destination: destination)
    }
  }

  private func cancelEmailPreparation() {
    emailPreparation?.cancel()
    emailPreparation = nil
    emailPreparationID = nil
    emailPreparationError = nil
  }

  private func discardEmailPreparation() {
    cancelEmailPreparation()
    requestedEmail = nil
    selection = nil
  }

  private func retryEmailPreparation() {
    guard let requestedEmail, let user, user.id == userID else { return }
    select(requestedEmail, user: user)
  }

  struct Selection: Identifiable {
    let user: AuthUser
    let bookID: Int
    let destination: Destination
    var emailModel: EmailBookDeliveryModel? = nil

    var id: String { "\(user.id).\(bookID).\(destination.id)" }
  }

  enum Destination: Identifiable {
    case kobo, catalog
    case email(Int?)
    case hardcover, storygraph

    var id: String {
      switch self {
      case .kobo: "kobo"
      case .catalog: "catalog"
      case .email(let fileID): "email.\(fileID ?? 0)"
      case .hardcover: "hardcover"
      case .storygraph: "storygraph"
      }
    }
  }
}
