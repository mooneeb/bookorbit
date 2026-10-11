import SwiftUI

struct BookSharingActionsView: View {
  let api: BookOrbitAPI
  let book: BookDetail
  let userID: Int
  @Binding var selection: Selection?
  @State private var user: AuthUser?
  @State private var userNamespace: String?
  @State private var isLoadingUser = true

  var body: some View {
    Section {
      if let user, user.id == userID, permitsSharing(user) {
        actions(user)
      } else if isLoadingUser {
        ProgressView(String(localized: "Loading sharing permissions"))
      } else {
        Text(String(localized: "Sharing is unavailable for this account."))
      }
    } header: {
      Text(String(localized: "Share and deliver"))
        .task(id: userID) {
          guard userID > 0,
            let authenticated = try? await api.authenticatedUser(), authenticated.id == userID,
            let namespace = try? await api.imageNamespace()
          else {
            user = nil
            userNamespace = nil
            selection = nil
            isLoadingUser = false
            return
          }
          guard user != authenticated || userNamespace != namespace else { return }
          selection = nil
          user = authenticated
          userNamespace = namespace
          isLoadingUser = false
        }
    }
    .onChange(of: book.id) { selection = nil }
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
        files: book.files, initialFileID: fileID)
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
    selection = Selection(user: user, bookID: book.id, destination: destination)
  }

  struct Selection: Identifiable {
    let user: AuthUser
    let bookID: Int
    let destination: Destination

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
