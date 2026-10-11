import Foundation

struct MigrationSourceDraft {
  var type = "booklore"
  var name = "Booklore"
  var host = ""
  var port = "3306"
  var database = ""
  var username = ""
  var password = ""
  var ssl = false
  var mediaRootPath = ""
  var mode = "api"
  var baseURL = ""
  var apiToken = ""
  var allowPrivateNetwork = false
  var backupPath = ""
  var appDatabasePath = ""
  var metadataDatabasePath = ""

  var connectionConfig: [String: JSONValue] {
    switch type {
    case "audiobookshelf":
      if mode == "backup" {
        return [
          "mode": .string("backup"),
          "backupPath": .string(backupPath.trimmingCharacters(in: .whitespaces)),
        ]
      }
      return [
        "mode": .string("api"), "baseUrl": .string(baseURL.trimmingCharacters(in: .whitespaces)),
        "apiToken": .string(apiToken), "allowPrivateNetwork": .boolean(allowPrivateNetwork),
      ]
    case "calibre_web_automated":
      return [
        "mode": .string("snapshot"), "appDatabasePath": .string(appDatabasePath),
        "metadataDatabasePath": .string(metadataDatabasePath),
      ]
    default:
      return [
        "host": .string(host), "port": .number(Double(port) ?? 3306), "database": .string(database),
        "user": .string(username), "password": .string(password), "ssl": .boolean(ssl),
        "mediaRootPath": .string(mediaRootPath),
      ]
    }
  }

  mutating func receive(_ source: MigrationSourceApi) {
    type = source.type
    name = source.name
    let config = source.connectionConfig
    func string(_ key: String) -> String {
      if case .string(let value) = config[key] { return value }
      return ""
    }
    host = string("host")
    database = string("database")
    username = string("user")
    password = string("password")
    mediaRootPath = string("mediaRootPath")
    if case .number(let value) = config["port"] { port = String(Int(value)) }
    ssl = config["ssl"] == .boolean(true)
    mode = string("mode") == "backup" ? "backup" : "api"
    baseURL = string("baseUrl")
    apiToken = string("apiToken")
    backupPath = string("backupPath")
    allowPrivateNetwork = config["allowPrivateNetwork"] == .boolean(true)
    appDatabasePath = string("appDatabasePath")
    metadataDatabasePath = string("metadataDatabasePath")
  }

  mutating func clearSecrets() {
    password = ""
    apiToken = ""
  }
}

struct MigrationDuplicateChoice: Identifiable {
  let id: Int
  let candidates: [String]
  var selected = ""
}
