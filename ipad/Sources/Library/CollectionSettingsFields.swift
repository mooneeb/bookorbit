import SwiftUI

struct CollectionSettingsDraft {
  var name = ""
  var icon = "Folder"
  var isPublic = false

  init(collection: BookCollection? = nil) {
    name = collection?.name ?? ""
    icon = collection?.icon ?? "Folder"
    isPublic = collection?.isPublic ?? false
  }

  var isValid: Bool {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let icon = icon.trimmingCharacters(in: .whitespacesAndNewlines)
    return !name.isEmpty && name.count <= 255 && !icon.isEmpty
      && icon.count <= CollectionVocabulary.iconMaximum
  }
}

struct CollectionSettingsFields: View {
  @Binding var draft: CollectionSettingsDraft

  private let icons = [
    "Folder", "BookOpen", "Bookmark", "Heart", "Star", "Library", "Archive", "Headphones",
    "GraduationCap", "Compass", "Sparkles",
  ]

  var body: some View {
    Section("Collection") {
      TextField("Collection name", text: $draft.name)
        .accessibilityIdentifier("collectionName")
      Picker("Choose icon", selection: $draft.icon) {
        ForEach(icons, id: \.self) { icon in
          Label(icon, systemImage: CollectionIcon.symbol(for: icon) ?? "folder").tag(icon)
        }
        if !icons.contains(draft.icon) { Text(draft.icon).tag(draft.icon) }
      }
      .accessibilityIdentifier("collectionIconPicker")
      TextField("Icon name or emoji", text: $draft.icon)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .accessibilityIdentifier("collectionIcon")
      HStack {
        Text("Selected icon")
        Spacer()
        CollectionIcon(value: draft.icon)
      }
    }
    Section("Sharing") {
      Toggle("Share with other users", isOn: $draft.isPublic)
        .accessibilityIdentifier("shareCollection")
      Text("Shared collections show each person only books they can access.")
        .font(.body).fixedSize(horizontal: false, vertical: true)
    }
  }
}

struct CollectionIcon: View {
  let value: String?

  static func symbol(for value: String) -> String? {
    switch value.lowercased() {
    case "folder": "folder"
    case "bookopen": "book"
    case "bookmark": "bookmark"
    case "heart": "heart"
    case "star": "star"
    case "library": "books.vertical"
    case "archive": "archivebox"
    case "headphones": "headphones"
    case "graduationcap": "graduationcap"
    case "compass": "safari"
    case "sparkles": "sparkles"
    default: nil
    }
  }

  var body: some View {
    if let value, let symbol = Self.symbol(for: value) {
      Image(systemName: symbol).accessibilityHidden(true)
    } else if let value, value.count <= 4,
      value.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation })
    {
      Text(value).accessibilityHidden(true)
    } else {
      Image(systemName: "square.dashed").accessibilityLabel("Icon preview unavailable")
    }
  }
}
