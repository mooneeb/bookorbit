import SwiftUI

enum LibraryManagementDestination: String, CaseIterable, Identifiable {
  case acquisition, scanning, requests, requestAdministration, migration, entities, maintenance,
    maintenanceSettings

  var id: String { rawValue }

  var title: String {
    switch self {
    case .acquisition: "Acquire books"
    case .scanning: "Server scanning"
    case .requests: "Book Requests"
    case .requestAdministration: "Request administration"
    case .migration: "Migration imports"
    case .entities: "Manage entities"
    case .maintenance: "Library maintenance"
    case .maintenanceSettings: "Maintenance settings"
    }
  }

  var identifier: String {
    switch self {
    case .acquisition: "acquisitionEntry"
    case .scanning: "openServerScanning"
    case .requests: "openRequests"
    case .requestAdministration: "requestAdministration"
    case .migration: "migrationImportEntry"
    case .entities: "entityManagementEntry"
    case .maintenance: "maintenanceEntry"
    case .maintenanceSettings: "maintenanceSettingsEntry"
    }
  }

  func isAvailable(to user: AuthUser) -> Bool {
    switch self {
    case .acquisition:
      user.hasPermission(.libraryUpload) || user.hasPermission(.bookDockAccess)
    case .scanning:
      user.hasPermission(.manageLibraries)
        || (user.hasPermission(.bookDockAccess) && user.hasPermission(.manageBookDock))
    case .requests: user.hasPermission(.bookRequestAccess)
    case .requestAdministration, .migration, .maintenanceSettings:
      user.hasPermission(.manageAppSettings)
    case .entities: user.hasPermission(.libraryEditMetadata)
    case .maintenance:
      user.hasPermission(.libraryDeleteBooks) || user.hasPermission(.manageLibraries)
    }
  }
}

struct LibraryManagementSidebar: View {
  let user: AuthUser
  let open: (LibraryManagementDestination) -> Void

  var body: some View {
    let destinations = LibraryManagementDestination.allCases.filter { $0.isAvailable(to: user) }
    if !destinations.isEmpty {
      Section("Manage library") {
        ForEach(destinations) { destination in
          Button(destination.title) { open(destination) }
            .accessibilityIdentifier(destination.identifier)
        }
      }
    }
  }
}

struct LibraryManagementSheet: View {
  @Environment(\.dismiss) private var dismiss
  let destination: LibraryManagementDestination
  let session: SessionModel
  let api: BookOrbitAPI
  let openDock: () -> Void

  var body: some View {
    if let user = session.user, destination.isAvailable(to: user) {
      switch destination {
      case .acquisition:
        NavigationStack {
          AcquisitionView(api: api, user: user)
            .toolbar {
              ToolbarItem(placement: .confirmationAction) {
                Button("Done", action: dismiss.callAsFunction)
              }
            }
        }
      case .scanning: ServerScanningView(api: api, user: user, openDock: openDock)
      case .requests: RequestsView(session: session, api: api)
      case .requestAdministration: RequestAdministrationView(session: session)
      case .migration: MigrationView(api: api, user: user)
      case .entities: EntityManagementView(api: api, user: user)
      case .maintenance:
        NavigationStack {
          MaintenanceView(api: api, user: user)
            .toolbar {
              ToolbarItem(placement: .confirmationAction) {
                Button("Done", action: dismiss.callAsFunction)
              }
            }
        }
      case .maintenanceSettings:
        NavigationStack {
          MaintenanceSettingsView(api: api, user: user)
            .toolbar {
              ToolbarItem(placement: .confirmationAction) {
                Button("Done", action: dismiss.callAsFunction)
              }
            }
        }
      }
    } else {
      ContentUnavailableView("Access unavailable", systemImage: "lock")
    }
  }
}

struct LibraryBookSelectionRow: View {
  let book: BookCard
  let isSelected: Bool
  let canSelect: Bool
  let toggle: () -> Void

  var body: some View {
    Button(action: toggle) {
      HStack(spacing: 12) {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
          .font(.title2).accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 5) {
          Text(book.title ?? "Untitled book").font(.headline)
          Text(book.authors.joined(separator: ", ")).font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(.vertical, 8)
      .frame(minHeight: 44)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(!canSelect && !isSelected)
    .accessibilityLabel(book.title ?? "Untitled book")
    .accessibilityValue(isSelected ? "Selected" : "Not selected")
    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    .accessibilityIdentifier("selectBook\(book.id)")
  }
}
