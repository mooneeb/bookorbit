import XCTest

final class RequestAdministrationJourneyTests: XCTestCase {
  override func setUpWithError() throws {
    try super.setUpWithError()
    continueAfterFailure = false
  }

  @MainActor
  func testIPADE03AdminSourceClientConfiguration() async throws {
    try await controlProtocol("orphan=false")
    let app = launch(username: "ipad-settings-admin")
    let entry = app.descendants(matching: .any)["requestAdministration"].firstMatch
    XCTAssertTrue(entry.waitForExistence(timeout: 20))
    entry.tap()
    XCTAssertTrue(app.buttons["requestAdminAddSource"].waitForExistence(timeout: 15))
    XCTAssertFalse(app.descendants(matching: .any)["requestAdminPlugins"].firstMatch.exists)
    app.buttons["requestAdminAddSource"].tap()
    let sourceName = "Native source \(UUID().uuidString.prefix(8))"
    fill(app.textFields["requestSourceName"], sourceName)
    fill(app.textFields["requestSourceURL"], protocolOrigin + "/torznab")
    app.switches["requestSourcePrivateAddress"].tap()
    app.buttons["requestSourceColor"].tap()
    app.buttons["Teal"].tap()
    let resolvers = app.textFields["requestNetworkResolvers"]
    reveal(resolvers, in: app)
    fill(resolvers, "1.1.1.1,8.8.8.8")
    capture("IPAD-E03-REQUEST-ADMIN-native-source-form")
    let sourceSave = app.buttons["requestSourceSave"]
    reveal(sourceSave, in: app)
    sourceSave.tap()
    XCTAssertTrue(app.buttons["Test \(sourceName)"].waitForExistence(timeout: 15))
    app.buttons["Test \(sourceName)"].tap()
    XCTAssertTrue(app.staticTexts["Source connection verified."].waitForExistence(timeout: 15))
    capture("IPAD-E03-REQUEST-ADMIN-native-source-tested")
    app.buttons.matching(
      NSPredicate(
        format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "requestSource", sourceName)
    ).firstMatch.tap()
    XCTAssertTrue(app.buttons["requestSourceColor"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["requestSourceColor"].label.contains("Teal"))
    reveal(app.textFields["requestNetworkResolvers"], in: app)
    XCTAssertEqual(app.textFields["requestNetworkResolvers"].value as? String, "1.1.1.1,8.8.8.8")
    capture("IPAD-E03-REQUEST-ADMIN-native-source-network-persisted")
    app.navigationBars.buttons.firstMatch.tap()
    let addClient = app.buttons["requestAdminAddClient"]
    if !addClient.isHittable { app.swipeUp() }
    addClient.tap()
    let clientName = "Native client \(UUID().uuidString.prefix(8))"
    fill(app.textFields["requestClientName"], clientName)
    fill(app.textFields["requestClientURL"], protocolOrigin)
    let username = app.textFields["Username"]
    fill(username, "fixture")
    app.secureTextFields["Password"].tap()
    app.secureTextFields["Password"].typeText("fixture-password")
    app.switches["requestClientPrivateAddress"].tap()
    app.buttons["requestClientColor"].tap()
    app.buttons["Orange"].tap()
    app.swipeUp()
    fill(app.textFields["requestClientRemotePath"], "/downloads")
    fill(app.textFields["requestClientLocalPath"], "/tmp")
    capture("IPAD-E03-REQUEST-ADMIN-native-client-form")
    let save = app.buttons["requestClientSave"]
    if !save.isHittable { app.swipeUp() }
    save.tap()
    let testClient = app.buttons["Test \(clientName)"]
    XCTAssertTrue(testClient.waitForExistence(timeout: 15))
    if !testClient.isHittable { app.swipeUp() }
    testClient.tap()
    XCTAssertTrue(
      app.staticTexts["Download client connection verified."].waitForExistence(timeout: 15))
    capture("IPAD-E03-REQUEST-ADMIN-native-client-tested")
    let hardlink = app.buttons["Test hardlink: /downloads"]
    reveal(hardlink, in: app)
    hardlink.tap()
    XCTAssertTrue(app.staticTexts["Hardlink verified."].waitForExistence(timeout: 15))
    capture("IPAD-E03-REQUEST-ADMIN-native-hardlink-tested")
    let reconcile = app.buttons["Reconcile \(clientName)"]
    reveal(reconcile, in: app)
    reconcile.tap()
    XCTAssertTrue(app.staticTexts["requestClientReconciliationEmpty"].waitForExistence(timeout: 15))
    capture("IPAD-E03-REQUEST-ADMIN-native-reconciliation-empty")
    app.navigationBars.buttons.firstMatch.tap()
    try await controlProtocol("orphan=true")
    reveal(reconcile, in: app)
    reconcile.tap()
    let orphan = app.buttons["Remove orphaned download"]
    XCTAssertTrue(orphan.waitForExistence(timeout: 15))
    capture("IPAD-E03-REQUEST-ADMIN-native-reconciliation-orphan")
    orphan.tap()
    XCTAssertTrue(app.buttons["requestClientRemoveOrphan"].waitForExistence(timeout: 10))
    app.buttons["requestClientRemoveOrphan"].tap()
    XCTAssertTrue(app.staticTexts["requestClientReconciliationEmpty"].waitForExistence(timeout: 15))
    capture("IPAD-E03-REQUEST-ADMIN-native-reconciliation-orphan-removed")
  }

  @MainActor
  func testIPADE03ProwlarrSyncAndManagedSourceToggle() throws {
    let app = launch(username: "ipad-settings-admin")
    openAdministration(app)
    let add = app.buttons["requestAdminAddManager"]
    reveal(add, in: app)
    add.tap()
    let name = "Native manager \(UUID().uuidString.prefix(8))"
    fill(app.textFields["requestManagerName"], name)
    fill(app.textFields["requestManagerURL"], protocolOrigin)
    let key = app.secureTextFields["requestManagerCredential"]
    key.tap()
    key.typeText("fixture-prowlarr-key")
    app.switches["requestManagerPrivateAddress"].tap()
    app.buttons["requestManagerColor"].tap()
    app.buttons["Purple"].tap()
    reveal(app.textFields["requestNetworkResolvers"], in: app)
    fill(app.textFields["requestNetworkResolvers"], "1.1.1.1")
    capture("IPAD-E03-REQUEST-ADMIN-native-manager-form")
    let save = app.buttons["requestManagerSave"]
    reveal(save, in: app)
    save.tap()
    let manager = app.buttons[name]
    XCTAssertTrue(manager.waitForExistence(timeout: 15))
    reveal(manager, in: app)
    manager.tap()
    reveal(app.buttons["requestManagerTest"], in: app)
    app.buttons["requestManagerTest"].tap()
    XCTAssertTrue(app.staticTexts["Manager connection verified."].waitForExistence(timeout: 15))
    capture("IPAD-E03-REQUEST-ADMIN-native-manager-tested")
    app.buttons["requestManagerSync"].tap()
    XCTAssertTrue(manager.waitForExistence(timeout: 15))
    reveal(manager, in: app)
    manager.tap()
    let disable = app.buttons["Disable E03 managed source"]
    reveal(disable, in: app)
    XCTAssertTrue(disable.waitForExistence(timeout: 15))
    capture("IPAD-E03-REQUEST-ADMIN-native-manager-synced")
    disable.tap()
    XCTAssertTrue(manager.waitForExistence(timeout: 15))
    reveal(manager, in: app)
    manager.tap()
    let enable = app.buttons["Enable E03 managed source"]
    reveal(enable, in: app)
    XCTAssertTrue(enable.waitForExistence(timeout: 15))
    capture("IPAD-E03-REQUEST-ADMIN-native-managed-source-disabled")
  }

  @MainActor
  func testIPADE03PluginFilesPickerReviewInstallCheckAndRemove() throws {
    let app = launch(username: "ipad-owner")
    openAdministration(app)
    let plugins = app.buttons["requestAdminPlugins"]
    reveal(plugins, in: app)
    plugins.tap()
    app.buttons["requestPluginChoose"].tap()
    let browse = app.buttons["Browse"].firstMatch
    if browse.waitForExistence(timeout: 3) { browse.tap() }
    let onDevice = app.descendants(matching: .any).matching(
      NSPredicate(format: "label == %@", "On My iPad")
    ).firstMatch
    if onDevice.waitForExistence(timeout: 3) { onDevice.tap() }
    let folder = app.descendants(matching: .any).matching(
      NSPredicate(format: "label == %@", "BookOrbit")
    ).firstMatch
    if folder.waitForExistence(timeout: 3) { folder.tap() }
    let file = app.descendants(matching: .any).matching(
      NSPredicate(format: "label CONTAINS %@", "E03 controlled plugin")
    ).firstMatch
    XCTAssertTrue(file.waitForExistence(timeout: 10))
    file.tap()
    XCTAssertTrue(app.staticTexts["requestPluginSourceReview"].waitForExistence(timeout: 15))
    XCTAssertTrue(app.staticTexts["requestPluginSourceReview"].label.contains("resolveFile"))
    capture("IPAD-E03-REQUEST-ADMIN-native-plugin-source-review")
    let install = app.buttons["requestPluginInstall"]
    reveal(install, in: app)
    install.tap()
    app.buttons["Install reviewed plugin"].tap()
    let installed = app.buttons["Remove E03 native plugin"]
    XCTAssertTrue(installed.waitForExistence(timeout: 20))
    capture("IPAD-E03-REQUEST-ADMIN-native-plugin-installed")
    let updates = app.buttons["requestPluginCheckUpdates"]
    reveal(updates, in: app)
    updates.tap()
    let status = app.staticTexts["requestPluginUpdateStatuse03-native-plugin"]
    XCTAssertTrue(status.waitForExistence(timeout: 15))
    XCTAssertTrue(status.label.contains("unsupported"))
    capture("IPAD-E03-REQUEST-ADMIN-native-plugin-unsupported-update")
    reveal(installed, in: app)
    installed.tap()
    app.buttons["Remove plugin and sources"].tap()
    XCTAssertTrue(
      app.staticTexts["Plugin and configured sources removed."].waitForExistence(timeout: 15))
    XCTAssertFalse(installed.exists)
    capture("IPAD-E03-REQUEST-ADMIN-native-plugin-removed")
  }

  @MainActor
  func testIPADE03AutomationDestinationAndReleaseTierPersist() throws {
    let app = launch(username: "ipad-settings-admin")
    openAdministration(app)
    let automation = app.buttons["requestAdminAutomation"]
    reveal(automation, in: app)
    automation.tap()
    let formats = app.buttons["requestAutomationFormats"]
    reveal(formats, in: app)
    formats.tap()
    app.buttons["Preferred format"].tap()
    let library = app.buttons["requestAutomationLibraryebook"]
    reveal(library, in: app)
    library.tap()
    app.buttons["Large library"].tap()
    let tiers = app.buttons["Ebook tiers"]
    reveal(tiers, in: app)
    tiers.tap()
    app.buttons["Add tier"].tap()
    app.buttons["New tier"].tap()
    fill(app.textFields["Tier name"], "Native PDF preferred")
    let pdf = app.switches["PDF"]
    reveal(pdf, in: app)
    pdf.tap()
    capture("IPAD-E03-REQUEST-ADMIN-native-release-tier")
    app.navigationBars.buttons.firstMatch.tap()
    app.navigationBars.buttons.firstMatch.tap()
    let save = app.buttons["requestAutomationSave"]
    reveal(save, in: app)
    save.tap()
    XCTAssertTrue(app.staticTexts["requestAutomationSaved"].waitForExistence(timeout: 15))
    capture("IPAD-E03-REQUEST-ADMIN-native-automation-saved")
    app.navigationBars.buttons.firstMatch.tap()
    reveal(automation, in: app)
    automation.tap()
    reveal(app.buttons["requestAutomationLibraryebook"], in: app)
    XCTAssertTrue(app.buttons["requestAutomationLibraryebook"].label.contains("Large library"))
    reveal(tiers, in: app)
    tiers.tap()
    XCTAssertTrue(app.buttons["Native PDF preferred"].waitForExistence(timeout: 15))
    app.buttons["Native PDF preferred"].tap()
    reveal(pdf, in: app)
    XCTAssertEqual(pdf.value as? String, "1")
    capture("IPAD-E03-REQUEST-ADMIN-native-automation-reloaded")
  }

  @MainActor
  func testIPADE03ReaderRequestPreferencePersists() throws {
    let app = launch(username: "ipad-reader")
    app.buttons["openRequests"].tap()
    let preferences = app.buttons["requestPreferences"]
    reveal(preferences, in: app)
    preferences.tap()
    let language = app.buttons["requestDefaultLanguage"]
    XCTAssertTrue(language.waitForExistence(timeout: 10))
    language.tap()
    app.buttons["German"].tap()
    app.buttons["Save preferences"].tap()
    XCTAssertTrue(app.staticTexts["Request preferences saved."].waitForExistence(timeout: 15))
    capture("IPAD-E03-REQUEST-ADMIN-native-reader-preference-saved")
    app.navigationBars.buttons.firstMatch.tap()
    reveal(preferences, in: app)
    preferences.tap()
    XCTAssertTrue(language.waitForExistence(timeout: 10))
    XCTAssertTrue(language.label.contains("German"))
    capture("IPAD-E03-REQUEST-ADMIN-native-reader-preference-reloaded")
  }

  @MainActor
  func testIPADE03ModeratorCannotAccessConfiguration() throws {
    let app = launch(username: "ipad-request-moderator")
    XCTAssertFalse(app.descendants(matching: .any)["requestAdministration"].firstMatch.exists)
    capture("IPAD-E03-REQUEST-ADMIN-moderator-permissions")
  }

  @MainActor
  private func launch(username: String) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    app.launch()
    if app.buttons["signOut"].exists { app.buttons["signOut"].tap() }
    if app.buttons["Change server"].exists { app.buttons["Change server"].tap() }
    let server = app.textFields["serverURL"]
    XCTAssertTrue(server.waitForExistence(timeout: 10))
    fill(
      server, ProcessInfo.processInfo.environment["IPAD_E03_SERVER_URL"] ?? "http://localhost:16482"
    )
    app.buttons["connectServer"].tap()
    XCTAssertTrue(app.textFields["username"].waitForExistence(timeout: 10))
    fill(app.textFields["username"], username)
    app.secureTextFields["password"].tap()
    app.secureTextFields["password"].typeText("IpadFixture123")
    app.buttons["signIn"].tap()
    XCTAssertTrue(app.buttons["signOut"].waitForExistence(timeout: 20))
    return app
  }

  private var protocolOrigin: String {
    ProcessInfo.processInfo.environment["IPAD_E03_PROTOCOL_URL"] ?? "http://127.0.0.1:16502"
  }

  @MainActor
  private func controlProtocol(_ query: String) async throws {
    let url = try XCTUnwrap(URL(string: "\(protocolOrigin)/control?\(query)"))
    let (_, response) = try await URLSession.shared.data(from: url)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
  }

  @MainActor
  private func openAdministration(_ app: XCUIApplication) {
    let entry = app.descendants(matching: .any)["requestAdministration"].firstMatch
    XCTAssertTrue(entry.waitForExistence(timeout: 20))
    entry.tap()
    XCTAssertTrue(app.buttons["requestAdminAddSource"].waitForExistence(timeout: 15))
  }

  @MainActor
  private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
    for _ in 0..<8 where !element.isHittable { app.swipeUp() }
    XCTAssertTrue(element.isHittable)
  }

  @MainActor
  private func fill(_ field: XCUIElement, _ value: String) {
    XCTAssertTrue(field.waitForExistence(timeout: 5))
    field.tap()
    let current = field.value as? String ?? ""
    if current != field.placeholderValue && !current.isEmpty {
      field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
    }
    field.typeText(value)
  }

  @MainActor
  private func capture(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
