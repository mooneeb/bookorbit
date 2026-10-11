import SwiftUI

enum NativeFeatureDestination: String, CaseIterable, Identifiable {
  case statistics, privacy, kobo, catalog, email, hardcover, readwise, storygraph

  var id: String { rawValue }

  var title: String {
    switch self {
    case .statistics: String(localized: "Reading statistics")
    case .privacy: String(localized: "Reading privacy and insights")
    case .kobo: String(localized: "Kobo")
    case .catalog: String(localized: "KOReader and OPDS")
    case .email: String(localized: "Email and Kindle")
    case .hardcover: String(localized: "Hardcover")
    case .readwise: String(localized: "Readwise")
    case .storygraph: String(localized: "StoryGraph")
    }
  }

  var identifier: String {
    switch self {
    case .statistics: "readingStatistics"
    case .privacy: "readingPrivacy"
    case .kobo: "koboSettings"
    case .catalog: "catalogSettings"
    case .email: "emailSettings"
    case .hardcover: "hardcoverSettings"
    case .readwise: "readwiseSettingsLink"
    case .storygraph: "storygraphSettings"
    }
  }

  func isPermitted(for user: AuthUser) -> Bool {
    switch self {
    case .statistics, .privacy: true
    case .kobo: user.hasPermission(.koboSync)
    case .catalog: user.hasPermission(.koreaderSync) || user.hasPermission(.opdsAccess)
    case .email: user.hasPermission(.emailSend)
    case .hardcover: user.hasPermission(.hardcoverSync)
    case .readwise: user.hasPermission(.readwiseSync)
    case .storygraph: user.hasPermission(.storygraphSync)
    }
  }
}

struct NativeFeatureDestinationView: View {
  let destination: NativeFeatureDestination
  let api: BookOrbitAPI
  let user: AuthUser

  var body: some View {
    if destination.isPermitted(for: user) {
      switch destination {
      case .statistics: ReadingStatisticsView(api: api, user: user)
      case .privacy: ReadingPrivacyView(api: api, user: user)
      case .kobo: KoboSettingsView(api: api, user: user)
      case .catalog: CatalogSettingsView(api: api, user: user)
      case .email: EmailSettingsView(api: api, user: user)
      case .hardcover:
        NativeDismissibleFeatureView(identifier: "externalServicesDone") {
          HardcoverSettingsView(api: api)
        }
      case .readwise: ReadwiseSettingsView(api: api)
      case .storygraph: StoryGraphSettingsView(api: api)
      }
    }
  }
}

struct NativeDismissibleFeatureView<Content: View>: View {
  let identifier: String
  @ViewBuilder let content: () -> Content
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      content()
        .toolbar {
          ToolbarItem(placement: .confirmationAction) {
            Button(String(localized: "Done"), action: dismiss.callAsFunction)
              .accessibilityIdentifier(identifier)
          }
        }
    }
  }
}
