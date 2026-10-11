import CryptoKit
import PDFKit
import XCTest

final class EmailDeliveryJourneyTests: XCTestCase {
  private let accessibilityAudit = E04AccessibilityAudit()
  override func setUpWithError() throws { continueAfterFailure = false }
  private var serverURL: String {
    ProcessInfo.processInfo.environment["IPAD_E04_NATIVE_SERVER_URL"] ?? ProcessInfo.processInfo
      .environment["IPAD_E04_BASE_URL"] ?? "http://localhost:16502"
  }
  private var smtpPort: String {
    ProcessInfo.processInfo.environment["IPAD_E04_SMTP_PORT"] ?? "17488"
  }
  private var receiverURL: String {
    ProcessInfo.processInfo.environment["IPAD_E04_SMTP_HTTP_URL"] ?? "http://localhost:17489"
  }

  override func tearDownWithError() throws {
    accessibilityAudit.reportFailures(testCase: self)
    try super.tearDownWithError()
  }

  @MainActor
  func testIPADE04A03NativeMailSettingsSelectedFileAndReceiver() async throws {
    try await withControlSession { token in
      let app = self.signIn(username: "ipad-owner")
      let names = self.configureUniqueMailSettings(app)
      let fixture = try await self.fixture(named: names, token: token)
      try await self.publishSetup(fixture)
      app.buttons["Done"].tap()
      try await self.runSelectedDelivery(app: app, fixture: fixture, token: token)
    }
  }

  @MainActor
  func testIPADE04A03NativeUniqueSetupAndSaveFeedback() async throws {
    try await withControlSession { token in
      let app = self.signIn(username: "ipad-owner")
      let names = self.configureUniqueMailSettings(app)
      let fixture = try await self.fixture(named: names, token: token)
      try await self.assertFixture(fixture, token: token)
      try await self.publishSetup(fixture)
    }
  }

  @MainActor
  func testIPADE04A03NativeRetainedDefaultsSaveFeedback() async throws {
    try await withControlSession { token in
      let fixture = Self.retainedFixture
      try await self.assertFixture(fixture, token: token, requirePlainSMTP: false)
      let app = self.signIn(username: "ipad-owner", url: self.faultURL)
      app.buttons["emailSettings"].tap()
      XCTAssertTrue(app.buttons["emailSaveDefaults"].waitForExistence(timeout: 15))
      self.assertSelectedDefaults(app, fixture: fixture)
      app.buttons["emailSaveDefaults"].tap()
      self.assertSaveFeedback(app)
      self.capture("EMAIL-M03-retained-defaults-success-visible")
      try await self.assertFixture(fixture, token: token, requirePlainSMTP: false)
      try await self.setAPIConnection(available: false)
      do {
        app.buttons["emailSaveDefaults"].tap()
        let error = app.staticTexts["emailSettingsError"]
        XCTAssertTrue(error.wait(for: \.isHittable, toEqual: true, timeout: 15))
        XCTAssertFalse(app.staticTexts["emailSettingsNotice"].exists)
        self.assertSelectedDefaults(app, fixture: fixture)
        self.capture("EMAIL-M03-retained-defaults-error-visible")
        try await self.assertFixture(fixture, token: token, requirePlainSMTP: false)
      } catch {
        try? await self.setAPIConnection(available: true)
        throw error
      }
      try await self.setAPIConnection(available: true)
      app.buttons["emailSaveDefaults"].tap()
      self.assertSaveFeedback(app)
      XCTAssertFalse(app.staticTexts["emailSettingsError"].exists)
      self.assertSelectedDefaults(app, fixture: fixture)
      self.capture("EMAIL-M03-retained-defaults-recovered-visible")
      try await self.assertFixture(fixture, token: token, requirePlainSMTP: false)
    }
  }

  @MainActor
  func testIPADE04A03NativeRetainedProviderEditorSaveCheckpoint() async throws {
    try await withControlSession { token in
      let fixture = Self.retainedFixture
      try await self.assertFixture(fixture, token: token, requirePlainSMTP: false)
      let app = self.signIn(username: "ipad-owner")
      try await self.preparePlainSMTP(app: app, fixture: fixture, token: token)
    }
  }

  @MainActor
  func testIPADE04A03NativeRetainedSharingRenderCheckpoint() async throws {
    try await withControlSession { token in
      let fixture = Self.retainedFixture
      try await self.assertFixture(fixture, token: token)
      let jobsBefore = try await self.jobs(token: token)
      let messagesBefore = try await self.receivedMessages()
      let detailData = try await self.api("books/1", token: token)
      let detail = try XCTUnwrap(JSONSerialization.jsonObject(with: detailData) as? [String: Any])
      let title = try XCTUnwrap(detail["title"] as? String)
      let app = self.signIn(username: "ipad-owner")
      if app.buttons["All books"].exists { app.buttons["All books"].tap() }
      XCTAssertTrue(app.buttons["Table"].waitForExistence(timeout: 10))
      app.buttons["Table"].tap()
      let search = app.textViews["librarySearch"]
      XCTAssertTrue(search.waitForExistence(timeout: 10))
      self.replace(search, text: "\(title)\n")
      let book = app.buttons["tableOpen1_title"]
      XCTAssertTrue(book.wait(for: \.isHittable, toEqual: true, timeout: 15))
      book.tap()
      XCTAssertTrue(app.buttons["Book details"].waitForExistence(timeout: 10))
      app.buttons["Book details"].tap()
      XCTAssertTrue(app.navigationBars["Book details"].waitForExistence(timeout: 10))
      let delivery = app.buttons["emailBookFile1"]
      self.reveal(delivery, app: app)
      XCTAssertTrue(app.staticTexts["Share and deliver"].exists)
      XCTAssertTrue(delivery.isHittable)
      XCTAssertTrue(app.buttons["sendBookByEmail"].exists)
      XCTAssertTrue(app.buttons["deliverToKobo"].exists)
      XCTAssertTrue(app.buttons["catalogBookDelivery"].exists)
      self.capture("EMAIL-M03-retained-sharing-actions-mounted")
      delivery.tap()
      let send = app.buttons["emailSendSelectedFile"]
      XCTAssertTrue(send.wait(for: \.isEnabled, toEqual: true, timeout: 15))
      XCTAssertTrue(send.isHittable)
      self.assertPicker(app.buttons["emailBookFile"], contains: "orbit.pdf")
      self.assertPicker(app.buttons["emailBookProvider"], contains: fixture.providerName)
      self.assertPicker(app.buttons["emailBookRecipient"], contains: fixture.recipientName)
      self.capture("EMAIL-M03-retained-selected-file-rendered-without-send")
      let done = app.navigationBars["Send by email"].buttons["Done"]
      XCTAssertTrue(done.isHittable)
      done.tap()
      XCTAssertTrue(app.navigationBars["Book details"].waitForExistence(timeout: 10))
      self.reveal(delivery, app: app)
      delivery.tap()
      XCTAssertTrue(send.wait(for: \.isEnabled, toEqual: true, timeout: 15))
      XCTAssertTrue(send.isHittable)
      self.assertPicker(app.buttons["emailBookFile"], contains: "orbit.pdf")
      self.assertPicker(app.buttons["emailBookProvider"], contains: fixture.providerName)
      self.assertPicker(app.buttons["emailBookRecipient"], contains: fixture.recipientName)
      self.capture("EMAIL-M03-retained-selected-file-reopened-without-send")
      let jobsAfter = try await self.jobs(token: token)
      let messagesAfter = try await self.receivedMessages()
      XCTAssertEqual(
        jobsAfter.compactMap { $0["id"] as? Int }, jobsBefore.compactMap { $0["id"] as? Int })
      XCTAssertEqual(
        messagesAfter.compactMap { $0["id"] as? Int },
        messagesBefore.compactMap { $0["id"] as? Int })
      try await self.assertFixture(fixture, token: token)
    }
  }

  @MainActor
  func testIPADE04A03NativeRetainedSelectedPDFDeliveryAndRetry() async throws {
    try await withControlSession { token in
      let fixture = Self.retainedFixture
      try await self.assertFixture(fixture, token: token)
      let app = self.signIn(username: "ipad-owner")
      try await self.runSelectedDelivery(app: app, fixture: fixture, token: token)
    }
  }

  @MainActor
  func testIPADE04A03NativeRetainedAcceptedDeliveryAccessibilityCheckpoint() async throws {
    try await withControlSession { token in
      let fixture = Self.retainedFixture
      let baseline = try await self.retainedAcceptedDelivery(fixture: fixture, token: token)
      let app = self.signIn(username: "ipad-owner")
      try await self.openRetainedSelectedDelivery(app: app, fixture: fixture, token: token)
      let accepted = app.staticTexts["emailStatus4"]
      self.reveal(accepted, app: app)
      XCTAssertEqual(accepted.label, "Accepted by mail server")
      self.capture("EMAIL-M03-retained-job4-accepted-without-send")
      do {
        try self.auditSelectedDelivery(app, state: "EMAIL-M03-retained-job4")
      } catch {
        try await self.assertRetainedDeliveryUnchanged(baseline, fixture: fixture, token: token)
        throw error
      }
      try await self.assertRetainedDeliveryUnchanged(baseline, fixture: fixture, token: token)
    }
  }

  @MainActor
  func testIPADE04A03NativeRetainedRejectedSendRetryContinuation() async throws {
    try await withControlSession { token in
      let fixture = Self.retainedFixture
      let baseline = try await self.retainedAcceptedDelivery(fixture: fixture, token: token)
      let previousJobIDs = Set(baseline.jobs.compactMap { $0["id"] as? Int })
      let app = self.signIn(username: "ipad-owner")
      try await self.openRetainedSelectedDelivery(app: app, fixture: fixture, token: token)
      try self.auditSelectedDelivery(app, state: "EMAIL-M03-retained-before-first-rejection")
      try await self.assertRetainedDeliveryUnchanged(baseline, fixture: fixture, token: token)
      try await self.setReceiverMode("reject")
      do {
        app.buttons["emailSendSelectedFile"].tap()
        let createdJobID = try await self.newDeliveryJobID(token: token, excluding: previousJobIDs)
        let scheduled = try self.revealEmailHistoryStatus(app, jobID: createdJobID)
        XCTAssertTrue(scheduled.wait(for: \.label, toEqual: "Retry scheduled", timeout: 15))
        self.capture("IPAD-E04-A03-email-rejection-retry-scheduled")
        let retryJobs = try await self.jobs(token: token).filter {
          !previousJobIDs.contains($0["id"] as? Int ?? -1)
        }
        XCTAssertEqual(retryJobs.count, 1)
        let retryJob = try XCTUnwrap(retryJobs.first)
        let retryJobID = try XCTUnwrap(retryJob["id"] as? Int)
        self.assertSelectedJob(retryJob, fixture: fixture)
        XCTAssertEqual(retryJob["status"] as? String, "pending")
        XCTAssertEqual(retryJob["attemptCount"] as? Int, 1)
        XCTAssertNotNil(retryJob["nextRetryAt"] as? String)
        let rejectedMessages = try await self.receivedMessages()
        XCTAssertEqual(rejectedMessages as NSArray, baseline.messages as NSArray)
        self.attach(
          try JSONSerialization.data(withJSONObject: retryJobs),
          name: "IPAD-E04-A03-native-scheduled-retry-job", type: "public.json")
        try await self.setReceiverMode("accept")
        let accepted = app.staticTexts["emailDeliveryNotice"]
        XCTAssertTrue(
          accepted.wait(
            for: \.label,
            toEqual: "Accepted by mail server. Check the recipient device for final delivery.",
            timeout: 45))
        self.capture("IPAD-E04-A03-email-retry-accepted")
        try self.auditSelectedDelivery(app, state: "IPAD-E04-A03-email-retry-accepted")
        let finalJobs = try await self.jobs(token: token)
        let finalNewJobs = finalJobs.filter { !previousJobIDs.contains($0["id"] as? Int ?? -1) }
        XCTAssertEqual(finalNewJobs.count, 1)
        XCTAssertEqual(finalNewJobs.first?["id"] as? Int, retryJobID)
        XCTAssertEqual(finalNewJobs.first?["status"] as? String, "sent")
        XCTAssertEqual(finalNewJobs.first?["attemptCount"] as? Int, 1)
        self.assertSelectedJob(try XCTUnwrap(finalNewJobs.first), fixture: fixture)
        XCTAssertEqual(
          finalJobs.filter { previousJobIDs.contains($0["id"] as? Int ?? -1) } as NSArray,
          baseline.jobs as NSArray)
        let sourceAfter = try await self.api("books/files/1/serve", token: token)
        XCTAssertEqual(sourceAfter, baseline.source)
        let messages = try await self.receivedMessages()
        XCTAssertEqual(
          messages.count, 2, "Only the accepted initial send and retry produce messages.")
        XCTAssertEqual(
          messages.first { $0["id"] as? Int == 1 } as NSDictionary?,
          baseline.messages.first as NSDictionary?)
        for message in messages {
          try self.assertSelectedMessage(message, source: sourceAfter, fixture: fixture)
        }
        let correlatedJobs = finalJobs.filter { [4, retryJobID].contains($0["id"] as? Int ?? -1) }
        XCTAssertEqual(correlatedJobs.count, 2)
        XCTAssertEqual(correlatedJobs.compactMap { $0["attemptCount"] as? Int }.sorted(), [0, 1])
        self.attach(
          try JSONSerialization.data(withJSONObject: correlatedJobs),
          name: "IPAD-E04-A03-native-correlated-jobs", type: "public.json")
        self.attach(
          try JSONSerialization.data(withJSONObject: messages),
          name: "IPAD-E04-A03-email-independent-SMTP-messages", type: "public.json")
        self.attach(
          baseline.source, name: "IPAD-E04-A03-native-selected-source-before", type: "com.adobe.pdf"
        )
        self.attach(
          sourceAfter, name: "IPAD-E04-A03-native-selected-source-after", type: "com.adobe.pdf")
        try await self.assertFixture(fixture, token: token)
        try await self.publishDelivery(fixture)
        try await self.assertDeliveryHandoff(fixture)
      } catch {
        try? await self.setReceiverMode("accept")
        throw error
      }
    }
  }

  @MainActor
  func testIPADE04A03NativeRetainedSentRetryHistoryCompletion() async throws {
    try await withControlSession { token in
      let fixture = Self.retainedFixture
      let baseline = try await self.retainedSentRetryDelivery(fixture: fixture, token: token)
      let app = self.signIn(username: "ipad-owner")
      try await self.openRetainedSelectedDelivery(app: app, fixture: fixture, token: token)
      try self.auditSelectedDelivery(app, state: "EMAIL-M03-retained-sent-job5-selected-dialog")
      try self.assertRetainedSentHistory(app, fixture: fixture, jobs: baseline.jobs)
      self.capture("IPAD-E04-A03-email-retained-job5-accepted-history-without-send")
      try self.auditSelectedDelivery(app, state: "EMAIL-M03-retained-sent-job5-history")
      try self.assertRetainedSentHistory(app, fixture: fixture, jobs: baseline.jobs)
      try await self.assertRetainedDeliveryUnchanged(baseline, fixture: fixture, token: token)
      let evidence: [String: Any] = [
        "mode": "background_after_smtp_cleanup", "jobId": 5, "attemptCount": 2,
        "messageIds": [1, 2], "nativeAcceptedHistoryVerified": true,
        "nativePendingRetryFeedbackVerified": false,
        "nativeExplicitRecoveryFeedbackVerified": false,
      ]
      try await self.publishDelivery(fixture, recoveryEvidence: evidence)
      try await self.assertDeliveryHandoff(fixture)
      let handoffs = try await self.nativeHandoffs()
      let email = try XCTUnwrap((handoffs["A03"] as? [String: Any])?["email"] as? [String: Any])
      XCTAssertEqual(email["recoveryEvidence"] as? NSDictionary, evidence as NSDictionary)
    }
  }

  @MainActor
  func testIPADE04A03NativeSameRunSelectedPDFDeliveryAndRetry() async throws {
    try await withControlSession { token in
      let fixture = try await self.sameRunFixture()
      try await self.assertFixture(fixture, token: token)
      let app = self.signIn(username: "ipad-owner")
      try await self.runSelectedDelivery(app: app, fixture: fixture, token: token)
    }
  }

  @MainActor
  private func configureUniqueMailSettings(_ app: XCUIApplication) -> MailFixtureNames {
    app.buttons["emailSettings"].tap()
    XCTAssertTrue(app.buttons["emailAddProvider"].waitForExistence(timeout: 15))
    capture("IPAD-E04-A03-email-settings")
    let providerName = "E04 native SMTP \(UUID().uuidString.prefix(8))"
    let recipientAddress = "\(UUID().uuidString)@kindle.test"
    let recipientName = "E04 native Kindle \(UUID().uuidString.prefix(8))"
    app.buttons["emailAddProvider"].tap()
    replace(app.textFields["emailProviderName"], text: providerName)
    replace(app.textFields["emailSMTPHost"], text: "127.0.0.1")
    replace(app.textFields["emailSMTPPort"], text: smtpPort)
    setSwitch(app.switches["emailSMTPAuthentication"], enabled: false)
    setSwitch(app.switches["emailSMTPStartTLS"], enabled: false)
    let sender = app.textFields["emailSenderAddress"]
    reveal(sender, app: app)
    replace(sender, text: "sender@bookorbit.test")
    capture("IPAD-E04-A03-email-provider-draft")
    app.buttons["emailSaveProvider"].tap()
    XCTAssertTrue(app.staticTexts[providerName].waitForExistence(timeout: 15))
    let addRecipient = app.buttons["emailAddRecipient"]
    reveal(addRecipient, app: app)
    addRecipient.tap()
    replace(app.textFields["emailRecipientName"], text: recipientName)
    replace(app.textFields["emailRecipientAddress"], text: recipientAddress)
    app.buttons["emailRecipientDevice"].tap()
    app.buttons["Kindle"].tap()
    capture("IPAD-E04-A03-email-kindle-recipient-draft")
    app.buttons["emailSaveRecipient"].tap()
    XCTAssertTrue(app.staticTexts[recipientName].waitForExistence(timeout: 15))
    let defaults = app.buttons["emailDefaultProvider"]
    reveal(defaults, app: app, up: false)
    defaults.tap()
    app.buttons[providerName].tap()
    app.buttons["emailDefaultRecipient"].tap()
    app.buttons[recipientName].tap()
    app.buttons["emailSaveDefaults"].tap()
    assertSaveFeedback(app)
    capture("IPAD-E04-A03-email-defaults-saved")
    return .init(
      providerName: providerName, recipientName: recipientName, recipientAddress: recipientAddress)
  }

  @MainActor
  private func runSelectedDelivery(app: XCUIApplication, fixture: MailFixture, token: String)
    async throws
  {
    let sourceBefore = try await api("books/files/1/serve", token: token)
    let messagesBefore = try await receivedMessages()
    let messageIDs = Set(messagesBefore.compactMap { $0["id"] as? Int })
    let previousJobs = try await jobs(token: token)
    let jobIDs = Set(previousJobs.compactMap { $0["id"] as? Int })
    let detailData = try await api("books/1", token: token)
    let detail = try XCTUnwrap(JSONSerialization.jsonObject(with: detailData) as? [String: Any])
    let title = try XCTUnwrap(detail["title"] as? String)
    if app.buttons["All books"].exists { app.buttons["All books"].tap() }
    XCTAssertTrue(app.buttons["Table"].waitForExistence(timeout: 10))
    app.buttons["Table"].tap()
    let search = app.textViews["librarySearch"]
    XCTAssertTrue(search.waitForExistence(timeout: 10))
    replace(search, text: "\(title)\n")
    let book = app.buttons["tableOpen1_title"]
    XCTAssertTrue(book.wait(for: \.isHittable, toEqual: true, timeout: 15))
    book.tap()
    XCTAssertTrue(app.buttons["Book details"].waitForExistence(timeout: 10))
    app.buttons["Book details"].tap()
    XCTAssertTrue(app.navigationBars["Book details"].waitForExistence(timeout: 10))
    let delivery = app.buttons["emailBookFile1"]
    reveal(delivery, app: app)
    delivery.tap()
    XCTAssertTrue(app.buttons["emailSendSelectedFile"].waitForExistence(timeout: 15))
    capture("IPAD-E04-A03-email-selected-file")
    app.buttons["emailSendSelectedFile"].tap()
    let accepted = app.staticTexts[
      "Accepted by mail server. Check the recipient device for final delivery."]
    XCTAssertTrue(accepted.waitForExistence(timeout: 20))
    capture("IPAD-E04-A03-email-mail-server-accepted")
    try auditSelectedDelivery(app, state: "IPAD-E04-A03-email-mail-server-accepted")
    let firstJobs = try await jobs(token: token).filter { !jobIDs.contains($0["id"] as? Int ?? -1) }
    XCTAssertEqual(firstJobs.count, 1)
    let firstJobID = try XCTUnwrap(firstJobs.first?["id"] as? Int)
    XCTAssertEqual(firstJobs.first?["status"] as? String, "sent")
    try await setReceiverMode("reject")
    app.buttons["emailSendSelectedFile"].tap()
    let createdJobID = try await newDeliveryJobID(
      token: token, excluding: jobIDs.union([firstJobID]))
    let scheduled = try revealEmailHistoryStatus(app, jobID: createdJobID)
    XCTAssertTrue(scheduled.wait(for: \.label, toEqual: "Retry scheduled", timeout: 15))
    capture("IPAD-E04-A03-email-rejection-retry-scheduled")
    let retryJobs = try await jobs(token: token).filter {
      !jobIDs.contains($0["id"] as? Int ?? -1) && $0["id"] as? Int != firstJobID
    }
    XCTAssertEqual(retryJobs.count, 1)
    let retryJobID = try XCTUnwrap(retryJobs.first?["id"] as? Int)
    XCTAssertEqual(retryJobs.first?["status"] as? String, "pending")
    XCTAssertEqual(retryJobs.first?["attemptCount"] as? Int, 1)
    XCTAssertNotNil(retryJobs.first?["nextRetryAt"] as? String)
    attach(
      try JSONSerialization.data(withJSONObject: retryJobs),
      name: "IPAD-E04-A03-native-scheduled-retry-job", type: "public.json")
    try await setReceiverMode("accept")
    XCTAssertTrue(accepted.waitForExistence(timeout: 45))
    capture("IPAD-E04-A03-email-retry-accepted")
    let (messages, response) = try await E04FixtureHTTP.data(
      from: URL(string: "\(receiverURL)/messages")!)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    let received = try XCTUnwrap(JSONSerialization.jsonObject(with: messages) as? [[String: Any]])
    XCTAssertTrue(
      received.contains {
        ($0["raw"] as? String)?.lowercased().contains("subject: convert") == true
          && ($0["raw"] as? String)?.contains(fixture.recipientAddress) == true
      })
    let attachment = XCTAttachment(data: messages, uniformTypeIdentifier: "public.json")
    attachment.name = "IPAD-E04-A03-email-independent-SMTP-messages"
    attachment.lifetime = .keepAlways
    add(attachment)
    let newJobs = try await jobs(token: token).filter { !jobIDs.contains($0["id"] as? Int ?? -1) }
    XCTAssertEqual(
      newJobs.count, 2, "The native initial send and scheduled retry each own one job.")
    for job in newJobs {
      XCTAssertEqual(job["status"] as? String, "sent")
      XCTAssertEqual(job["providerId"] as? Int, fixture.providerID)
      XCTAssertEqual(job["bookFileId"] as? Int, 1)
      XCTAssertEqual(job["toEmail"] as? String, fixture.recipientAddress)
    }
    XCTAssertEqual(newJobs.compactMap { $0["attemptCount"] as? Int }.sorted(), [0, 1])
    XCTAssertEqual(Set(newJobs.compactMap { $0["id"] as? Int }), Set([firstJobID, retryJobID]))
    let sourceAfter = try await api("books/files/1/serve", token: token)
    XCTAssertEqual(
      sourceBefore, sourceAfter, "The locked source PDF stays current through native delivery.")
    let newMessages = received.filter { !messageIDs.contains($0["id"] as? Int ?? -1) }
    XCTAssertEqual(
      newMessages.count, 2, "Rejected SMTP attempt must not produce an accepted duplicate.")
    for message in newMessages {
      let raw = try XCTUnwrap(message["raw"] as? String)
      XCTAssertTrue(raw.lowercased().contains("subject: convert"))
      XCTAssertTrue(
        (message["recipients"] as? [String] ?? []).contains("<\(fixture.recipientAddress)>"))
      XCTAssertEqual(
        try attachmentBytes(raw), sourceBefore,
        "Each received selected PDF equals the actual current source snapshot.")
    }
    attach(sourceBefore, name: "IPAD-E04-A03-native-selected-source-before", type: "com.adobe.pdf")
    attach(sourceAfter, name: "IPAD-E04-A03-native-selected-source-after", type: "com.adobe.pdf")
    attach(
      try JSONSerialization.data(withJSONObject: newJobs),
      name: "IPAD-E04-A03-native-correlated-jobs", type: "public.json")
    try await publishDelivery(fixture)
  }

  @MainActor
  func testIPADE04A03RestrictedEmailControlsHidden() throws {
    let app = signIn(username: "ipad-restricted")
    XCTAssertFalse(app.buttons["emailSettings"].exists)
    capture("IPAD-E04-A03-email-restricted-controls")
  }

  @MainActor
  private func signIn(username: String, url: String? = nil) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    app.launch()
    if !app.textFields["serverURL"].waitForExistence(timeout: 5) {
      if app.buttons["signOut"].exists { app.buttons["signOut"].tap() }
      if app.buttons["Change server"].exists { app.buttons["Change server"].tap() }
    }
    replace(app.textFields["serverURL"], text: url ?? serverURL)
    app.buttons["connectServer"].tap()
    XCTAssertTrue(app.textFields["username"].waitForExistence(timeout: 10))
    replace(app.textFields["username"], text: username)
    replace(app.secureTextFields["password"], text: "IpadFixture123")
    app.buttons["signIn"].tap()
    XCTAssertTrue(app.buttons["signOut"].waitForExistence(timeout: 20))
    return app
  }
  @MainActor
  private func setReceiverMode(_ mode: String) async throws {
    var request = URLRequest(url: URL(string: "\(receiverURL)/mode")!)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: ["mode": mode])
    let (_, response) = try await E04FixtureHTTP.data(for: request)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 204)
  }
  @MainActor private func replace(_ field: XCUIElement, text: String) {
    XCTAssertTrue(field.wait(for: \.isHittable, toEqual: true, timeout: 10))
    field.tap()
    let value = field.value as? String ?? ""
    if !value.isEmpty {
      field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.utf16.count))
    }
    field.typeText(text)
  }
  @MainActor private func reveal(_ element: XCUIElement, app: XCUIApplication, up: Bool = true) {
    for _ in 0..<8 {
      if element.isHittable { return }
      if up { app.swipeUp() } else { app.swipeDown() }
    }
    XCTAssertTrue(element.isHittable)
  }
  @MainActor
  private func capture(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
  private struct MailFixtureNames {
    let providerName: String
    let recipientName: String
    let recipientAddress: String
  }
  private struct MailFixture: Sendable {
    let providerID: Int
    let providerName: String
    let recipientID: Int
    let recipientName: String
    let recipientAddress: String
  }
  private static let retainedFixture = MailFixture(
    providerID: 4, providerName: "E04 native SMTP 7CF2CC10",
    recipientID: 4, recipientName: "E04 native Kindle 7E7D49AF",
    recipientAddress: "47F5A498-6807-4AE4-A7F3-33E613AFA586@kindle.test")

  private struct RetainedDeliverySnapshot {
    let source: Data
    let jobs: [[String: Any]]
    let messages: [[String: Any]]
  }

  @MainActor
  private func retainedSentRetryDelivery(fixture: MailFixture, token: String) async throws
    -> RetainedDeliverySnapshot
  {
    try await assertFixture(fixture, token: token)
    let source = try await api("books/files/1/serve", token: token)
    XCTAssertEqual(source.count, 3669)
    XCTAssertEqual(
      digest(source), "7baeacd1115ba6ae7b01914937e78eb1281ccb7da9888ff857177f04b539e541")
    let detailData = try await api("books/1", token: token)
    let detail = try XCTUnwrap(JSONSerialization.jsonObject(with: detailData) as? [String: Any])
    let personalNote = try XCTUnwrap(detail["personalNote"] as? String)
    XCTAssertFalse(personalNote.isEmpty)
    let annotationsData = try await api(
      "books/1/annotations?page=1&pageSize=1&sortBy=createdAt&sortDir=desc&search=E04%20private%20highlight",
      token: token)
    let annotations = try XCTUnwrap(
      JSONSerialization.jsonObject(with: annotationsData) as? [String: Any])
    let annotation = try XCTUnwrap((annotations["items"] as? [[String: Any]])?.first)
    XCTAssertEqual(annotation["id"] as? Int, 241)
    let privateHighlight = try XCTUnwrap(annotation["text"] as? String)
    XCTAssertFalse(privateHighlight.isEmpty)
    let retainedJobs = try await jobs(token: token)
    let jobHashes = [
      1: "4c60ef54d2d1a32c617f8ddc07415302774189210928115d2f3c4d50bd7aefbf",
      2: "7e245881e00b844344580776a9503b9191551de66f8eae963be8b72cc09f5e66",
      3: "f27de94466b7dfa149810249e9cc235983c5e3116e0fb1f456a4b15cf92f1e75",
      4: "287183f333c6e2910b7d01f1f46b47d7cd76d726be8bd0ac883b1ac2c81edfb9",
      5: "16f705b8c35a16d57529b55201e18ffb2f7f1119a7ebcf666ead707d8fe92fac",
    ]
    XCTAssertEqual(retainedJobs.count, 5)
    XCTAssertEqual(Set(retainedJobs.compactMap { $0["id"] as? Int }), Set(jobHashes.keys))
    for job in retainedJobs {
      let id = try XCTUnwrap(job["id"] as? Int)
      XCTAssertEqual(try recordDigest(job), try XCTUnwrap(jobHashes[id]))
    }
    let correlated = retainedJobs.filter { [4, 5].contains($0["id"] as? Int ?? -1) }
    XCTAssertEqual(correlated.count, 2)
    XCTAssertEqual(correlated.compactMap { $0["attemptCount"] as? Int }.sorted(), [0, 2])
    for job in correlated {
      assertSelectedJob(job, fixture: fixture)
      XCTAssertEqual(job["status"] as? String, "sent")
      XCTAssertTrue(job["nextRetryAt"] is NSNull)
      XCTAssertTrue(job["errorMessage"] is NSNull)
    }
    let messages = try await receivedMessages()
    let messageHashes = [
      1: "920326688df63c63afe08646a4fef9502349460d4db5e6a1cb45f0960351ddd9",
      2: "14c87680e62f50607ab9cf42c2113a7e7843848566747c7935b5d682ebacbd1f",
    ]
    XCTAssertEqual(messages.count, 2)
    XCTAssertEqual(Set(messages.compactMap { $0["id"] as? Int }), Set(messageHashes.keys))
    for message in messages {
      let id = try XCTUnwrap(message["id"] as? Int)
      XCTAssertEqual(try recordDigest(message), try XCTUnwrap(messageHashes[id]))
      try assertSelectedMessage(message, source: source, fixture: fixture)
      let attachment = try attachmentBytes(try XCTUnwrap(message["raw"] as? String))
      let pdf = try XCTUnwrap(PDFDocument(data: attachment))
      XCTAssertEqual(pdf.pageCount, 3)
      for index in 0..<pdf.pageCount {
        let page = try XCTUnwrap(pdf.page(at: index))
        let text = try XCTUnwrap(page.string)
        for privateText in [personalNote, privateHighlight] {
          XCTAssertFalse(text.contains(privateText))
          XCTAssertFalse(page.annotations.contains { ($0.contents ?? "").contains(privateText) })
        }
      }
      attach(attachment, name: "EMAIL-M03-retained-message-\(id)-actual-PDF", type: "com.adobe.pdf")
    }
    let handoffs = try await nativeHandoffs()
    XCTAssertNil((handoffs["A03"] as? [String: Any])?["email"])
    attach(source, name: "EMAIL-M03-retained-current-source", type: "com.adobe.pdf")
    attach(detailData, name: "EMAIL-M03-retained-private-note-provenance", type: "public.json")
    attach(
      annotationsData, name: "EMAIL-M03-retained-private-highlight-provenance", type: "public.json")
    attach(
      try JSONSerialization.data(withJSONObject: retainedJobs),
      name: "IPAD-E04-A03-native-correlated-retained-jobs", type: "public.json")
    attach(
      try JSONSerialization.data(withJSONObject: messages),
      name: "IPAD-E04-A03-email-independent-retained-SMTP-messages", type: "public.json")
    return .init(source: source, jobs: retainedJobs, messages: messages)
  }

  private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private func recordDigest(_ record: [String: Any]) throws -> String {
    digest(
      try JSONSerialization.data(
        withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes]))
  }

  @MainActor
  private func emailDeliveryForm(_ app: XCUIApplication) throws -> XCUIElement {
    let navigation = app.navigationBars["Send by email"]
    XCTAssertTrue(navigation.exists)
    let frame = navigation.frame
    let forms = app.collectionViews.allElementsBoundByIndex.filter {
      let candidate = $0.frame
      return abs(candidate.minX - frame.minX) < 1 && abs(candidate.width - frame.width) < 1
        && candidate.intersects(frame) && $0.isHittable
    }
    XCTAssertEqual(forms.count, 1, "The active Send by email Form must be uniquely identified.")
    return try XCTUnwrap(forms.first)
  }

  @MainActor
  private func revealEmailHistoryStatus(_ app: XCUIApplication, jobID: Int) throws -> XCUIElement {
    for _ in 0..<8 {
      let form = try emailDeliveryForm(app)
      let status = form.descendants(matching: .any).matching(identifier: "emailStatus\(jobID)")
        .firstMatch
      if status.exists && status.isHittable { return status }
      form.swipeUp()
    }
    capture("EMAIL-M03-history-\(jobID)-reveal-failed")
    attach(
      Data(app.debugDescription.utf8), name: "EMAIL-M03-history-\(jobID)-unrevealed",
      type: "public.plain-text")
    let status = try emailDeliveryForm(app).descendants(matching: .any)
      .matching(identifier: "emailStatus\(jobID)").firstMatch
    return try XCTUnwrap(status.exists && status.isHittable ? status : nil)
  }

  @MainActor
  private func assertRetainedSentHistory(
    _ app: XCUIApplication, fixture: MailFixture, jobs: [[String: Any]]
  ) throws {
    let status = try revealEmailHistoryStatus(app, jobID: 5)
    XCTAssertEqual(status.label, "Accepted by mail server")
    let row = try emailDeliveryForm(app).cells.containing(.any, identifier: "emailStatus5")
      .firstMatch
    XCTAssertTrue(row.exists)
    XCTAssertTrue(row.staticTexts[fixture.recipientName].exists)
    XCTAssertTrue(row.staticTexts[fixture.recipientAddress].exists)
    XCTAssertTrue(row.staticTexts["Book 1, file 1"].exists)
    let job = try XCTUnwrap(jobs.first { $0["id"] as? Int == 5 })
    let sentAt = try XCTUnwrap(job["sentAt"] as? String)
    XCTAssertTrue(row.staticTexts["Accepted: \(sentAt)"].exists)
    XCTAssertFalse(row.buttons["emailRetry5"].exists)
    XCTAssertFalse(
      row.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Next retry:")).firstMatch
        .exists)
  }

  @MainActor
  private func newDeliveryJobID(token: String, excluding previousIDs: Set<Int>) async throws -> Int
  {
    for _ in 0..<15 {
      let created = try await jobs(token: token).filter {
        !previousIDs.contains($0["id"] as? Int ?? -1)
      }
      if !created.isEmpty {
        XCTAssertEqual(created.count, 1)
        return try XCTUnwrap(created.first?["id"] as? Int)
      }
      try await Task.sleep(for: .milliseconds(200))
    }
    XCTFail("The native Send must create exactly one public owned job.")
    return try XCTUnwrap(Optional<Int>.none)
  }

  @MainActor
  private func retainedAcceptedDelivery(fixture: MailFixture, token: String) async throws
    -> RetainedDeliverySnapshot
  {
    try await assertFixture(fixture, token: token)
    let source = try await api("books/files/1/serve", token: token)
    XCTAssertEqual(source.count, 3669)
    XCTAssertEqual(
      SHA256.hash(data: source).map { String(format: "%02x", $0) }.joined(),
      "7baeacd1115ba6ae7b01914937e78eb1281ccb7da9888ff857177f04b539e541")
    let detailData = try await api("books/1", token: token)
    let detail = try XCTUnwrap(JSONSerialization.jsonObject(with: detailData) as? [String: Any])
    let personalNote = try XCTUnwrap(detail["personalNote"] as? String)
    XCTAssertFalse(personalNote.isEmpty)
    let pdf = try XCTUnwrap(PDFDocument(data: source))
    XCTAssertEqual(pdf.pageCount, 3)
    for index in 0..<pdf.pageCount {
      let page = try XCTUnwrap(pdf.page(at: index))
      XCTAssertFalse((page.string ?? "").contains(personalNote))
      XCTAssertFalse(page.annotations.contains { ($0.contents ?? "").contains(personalNote) })
    }
    let retainedJobs = try await jobs(token: token)
    XCTAssertEqual(Set(retainedJobs.compactMap { $0["id"] as? Int }), Set([1, 2, 3, 4]))
    let accepted = try XCTUnwrap(retainedJobs.first { $0["id"] as? Int == 4 })
    assertSelectedJob(accepted, fixture: fixture)
    XCTAssertEqual(accepted["status"] as? String, "sent")
    XCTAssertEqual(accepted["attemptCount"] as? Int, 0)
    XCTAssertTrue(accepted["nextRetryAt"] is NSNull)
    let messages = try await receivedMessages()
    XCTAssertEqual(messages.count, 1)
    let originalMessage = try XCTUnwrap(messages.first)
    XCTAssertEqual(originalMessage["id"] as? Int, 1)
    try assertSelectedMessage(originalMessage, source: source, fixture: fixture)
    XCTAssertFalse(try XCTUnwrap(originalMessage["raw"] as? String).contains(personalNote))
    let handoffs = try await nativeHandoffs()
    XCTAssertNil((handoffs["A03"] as? [String: Any])?["email"])
    attach(source, name: "EMAIL-M03-retained-original-source", type: "com.adobe.pdf")
    attach(
      try JSONSerialization.data(withJSONObject: retainedJobs),
      name: "EMAIL-M03-retained-original-jobs", type: "public.json")
    attach(
      try JSONSerialization.data(withJSONObject: messages),
      name: "EMAIL-M03-retained-original-SMTP-message", type: "public.json")
    return .init(source: source, jobs: retainedJobs, messages: messages)
  }

  @MainActor
  private func assertRetainedDeliveryUnchanged(
    _ baseline: RetainedDeliverySnapshot, fixture: MailFixture, token: String
  ) async throws {
    let source = try await api("books/files/1/serve", token: token)
    let currentJobs = try await jobs(token: token)
    let messages = try await receivedMessages()
    XCTAssertEqual(source, baseline.source)
    XCTAssertEqual(currentJobs as NSArray, baseline.jobs as NSArray)
    XCTAssertEqual(messages as NSArray, baseline.messages as NSArray)
    try await assertFixture(fixture, token: token)
    let handoffs = try await nativeHandoffs()
    XCTAssertNil((handoffs["A03"] as? [String: Any])?["email"])
  }

  @MainActor
  private func assertSelectedJob(_ job: [String: Any], fixture: MailFixture) {
    XCTAssertEqual(job["userId"] as? Int, 1)
    XCTAssertEqual(job["bookId"] as? Int, 1)
    XCTAssertEqual(job["bookFileId"] as? Int, 1)
    XCTAssertEqual(job["providerId"] as? Int, fixture.providerID)
    XCTAssertEqual(job["toEmail"] as? String, fixture.recipientAddress)
    XCTAssertEqual(job["subject"] as? String, "convert")
  }

  @MainActor
  private func assertSelectedMessage(_ message: [String: Any], source: Data, fixture: MailFixture)
    throws
  {
    let raw = try XCTUnwrap(message["raw"] as? String)
    XCTAssertTrue(raw.lowercased().contains("subject: convert"))
    XCTAssertEqual(message["recipients"] as? [String], ["<\(fixture.recipientAddress)>"])
    XCTAssertEqual(try attachmentBytes(raw), source)
  }

  @MainActor
  private func openRetainedSelectedDelivery(
    app: XCUIApplication, fixture: MailFixture, token: String
  )
    async throws
  {
    let detailData = try await api("books/1", token: token)
    let detail = try XCTUnwrap(JSONSerialization.jsonObject(with: detailData) as? [String: Any])
    let title = try XCTUnwrap(detail["title"] as? String)
    if app.buttons["All books"].exists { app.buttons["All books"].tap() }
    XCTAssertTrue(app.buttons["Table"].waitForExistence(timeout: 10))
    app.buttons["Table"].tap()
    let search = app.textViews["librarySearch"]
    XCTAssertTrue(search.waitForExistence(timeout: 10))
    replace(search, text: "\(title)\n")
    let book = app.buttons["tableOpen1_title"]
    XCTAssertTrue(book.wait(for: \.isHittable, toEqual: true, timeout: 15))
    book.tap()
    XCTAssertTrue(app.buttons["Book details"].waitForExistence(timeout: 10))
    app.buttons["Book details"].tap()
    XCTAssertTrue(app.navigationBars["Book details"].waitForExistence(timeout: 10))
    let delivery = app.buttons["emailBookFile1"]
    reveal(delivery, app: app)
    delivery.tap()
    let send = app.buttons["emailSendSelectedFile"]
    XCTAssertTrue(send.wait(for: \.isEnabled, toEqual: true, timeout: 15))
    XCTAssertTrue(send.isHittable)
    assertPicker(app.buttons["emailBookFile"], contains: "orbit.pdf")
    assertPicker(app.buttons["emailBookProvider"], contains: fixture.providerName)
    assertPicker(app.buttons["emailBookRecipient"], contains: fixture.recipientName)
  }

  @MainActor
  private func auditSelectedDelivery(_ app: XCUIApplication, state: String) throws {
    accessibilityAudit.collect(app, screen: state, testCase: self)
  }

  @MainActor
  private func nativeHandoffs() async throws -> [String: Any] {
    let control = try XCTUnwrap(ProcessInfo.processInfo.environment["IPAD_E04_RECEIVER_URL"])
    let (data, response) = try await E04FixtureHTTP.data(
      from: try XCTUnwrap(URL(string: "\(control)/native-handoffs")))
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  @MainActor
  private func assertDeliveryHandoff(_ fixture: MailFixture) async throws {
    let handoffs = try await nativeHandoffs()
    let email = try XCTUnwrap((handoffs["A03"] as? [String: Any])?["email"] as? [String: Any])
    XCTAssertEqual(email["providerId"] as? Int, fixture.providerID)
    XCTAssertEqual(email["recipientId"] as? Int, fixture.recipientID)
    XCTAssertEqual(email["recipientAddress"] as? String, fixture.recipientAddress)
    XCTAssertEqual(email["setupReady"] as? Bool, true)
    XCTAssertEqual(email["bookId"] as? Int, 1)
    XCTAssertEqual(email["fileId"] as? Int, 1)
    XCTAssertEqual(email["expectedStatus"] as? String, "sent")
  }

  private var faultURL: String {
    ProcessInfo.processInfo.environment["IPAD_E04_FAULT_PROXY_URL"] ?? "http://127.0.0.1:16505"
  }

  @MainActor
  private func assertSaveFeedback(_ app: XCUIApplication) {
    let notice = app.staticTexts["emailSettingsNotice"]
    XCTAssertTrue(notice.wait(for: \.isHittable, toEqual: true, timeout: 15))
    XCTAssertEqual(notice.label, "Defaults saved.")
    XCTAssertTrue(app.buttons["emailSaveDefaults"].isHittable)
  }
  @MainActor
  private func assertSelectedDefaults(_ app: XCUIApplication, fixture: MailFixture) {
    assertPicker(app.buttons["emailDefaultProvider"], contains: fixture.providerName)
    assertPicker(app.buttons["emailDefaultRecipient"], contains: fixture.recipientName)
  }
  @MainActor
  private func assertPicker(_ picker: XCUIElement, contains text: String) {
    XCTAssertTrue(picker.isHittable)
    XCTAssertTrue(
      picker.label.contains(text) || (picker.value as? String ?? "").contains(text)
        || picker.staticTexts[text].exists)
  }
  @MainActor
  private func setSwitch(_ toggle: XCUIElement, enabled: Bool) {
    XCTAssertTrue(toggle.wait(for: \.isHittable, toEqual: true, timeout: 10))
    let target = enabled ? "1" : "0"
    guard let value = toggle.value as? String, ["0", "1"].contains(value) else {
      XCTFail("Native toggle must expose an actual boolean value.")
      return
    }
    if value != target {
      toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
    }
    let changed = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", target), object: toggle)
    XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
  }
  @MainActor
  private func preparePlainSMTP(app: XCUIApplication, fixture: MailFixture, token: String)
    async throws
  {
    let providerData = try await api("email/providers/\(fixture.providerID)", token: token)
    let provider = try XCTUnwrap(JSONSerialization.jsonObject(with: providerData) as? [String: Any])
    let providersBefore = try await api("email/providers", token: token)
    let recipientBefore = try await api("email/recipients/\(fixture.recipientID)", token: token)
    app.buttons["emailSettings"].tap()
    XCTAssertTrue(app.buttons["emailSaveDefaults"].waitForExistence(timeout: 15))
    let edit = app.buttons["emailEditProvider\(fixture.providerID)"]
    reveal(edit, app: app)
    edit.tap()
    let editor = app.navigationBars["Edit mail provider"]
    XCTAssertTrue(editor.waitForExistence(timeout: 10))
    XCTAssertEqual(
      app.textFields["emailProviderName"].value as? String, provider["name"] as? String)
    XCTAssertEqual(app.textFields["emailSMTPHost"].value as? String, provider["host"] as? String)
    XCTAssertEqual(
      app.textFields["emailSMTPPort"].value as? String,
      String(try XCTUnwrap(provider["port"] as? Int)))
    let auth = app.switches["emailSMTPAuthentication"]
    let startTLS = app.switches["emailSMTPStartTLS"]
    XCTAssertEqual(auth.value as? String, try XCTUnwrap(provider["auth"] as? Bool) ? "1" : "0")
    XCTAssertEqual(
      startTLS.value as? String, try XCTUnwrap(provider["startTls"] as? Bool) ? "1" : "0")
    let save = app.buttons["emailSaveProvider"]
    XCTAssertTrue(save.isEnabled)
    capture("EMAIL-H05-retained-provider-populated")
    let sender = app.textFields["emailSenderAddress"]
    reveal(sender, app: app)
    XCTAssertEqual(sender.value as? String, provider["fromAddress"] as? String)
    reveal(auth, app: app, up: false)
    setSwitch(auth, enabled: false)
    reveal(startTLS, app: app)
    setSwitch(startTLS, enabled: false)
    XCTAssertTrue(save.isEnabled)
    capture("EMAIL-H05-retained-provider-switches-off-save-enabled")
    save.tap()
    XCTAssertTrue(editor.wait(for: \.exists, toEqual: false, timeout: 15))
    XCTAssertFalse(app.staticTexts["emailEditorError"].exists)
    try await assertFixture(fixture, token: token)
    let providerAfterData = try await api("email/providers/\(fixture.providerID)", token: token)
    let providerAfter = try XCTUnwrap(
      JSONSerialization.jsonObject(with: providerAfterData) as? [String: Any])
    XCTAssertEqual(providerAfter["host"] as? String, provider["host"] as? String)
    XCTAssertEqual(providerAfter["fromAddress"] as? String, provider["fromAddress"] as? String)
    let providersAfter = try await api("email/providers", token: token)
    func providerIDs(_ data: Data) throws -> Set<Int> {
      Set(
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
          .compactMap { $0["id"] as? Int })
    }
    XCTAssertEqual(try providerIDs(providersBefore), try providerIDs(providersAfter))
    let recipientAfter = try await api("email/recipients/\(fixture.recipientID)", token: token)
    XCTAssertEqual(
      try JSONSerialization.jsonObject(with: recipientBefore) as? NSDictionary,
      try JSONSerialization.jsonObject(with: recipientAfter) as? NSDictionary)
    capture("EMAIL-H05-retained-provider-save-completed")
    app.buttons["Done"].tap()
  }
  @MainActor
  private func withControlSession(_ action: @MainActor (String) async throws -> Void) async throws {
    let login = try await api(
      "auth/login",
      body: [
        "username": "ipad-owner", "password": "IpadFixture123", "clientKind": "native",
        "deviceLabel": "Focused native email observation",
      ])
    let session = try XCTUnwrap(JSONSerialization.jsonObject(with: login) as? [String: Any])
    let token = try XCTUnwrap(session["accessToken"] as? String)
    let refresh = try XCTUnwrap(session["refreshToken"] as? String)
    do { try await action(token) } catch {
      _ = try? await api("auth/logout", body: ["refreshToken": refresh])
      throw error
    }
    _ = try await api("auth/logout", body: ["refreshToken": refresh])
  }
  @MainActor
  private func api(_ path: String, token: String? = nil, body: [String: Any]? = nil) async throws
    -> Data
  {
    var request = URLRequest(url: try XCTUnwrap(URL(string: "\(serverURL)/api/v1/\(path)")))
    request.timeoutInterval = 15
    request.httpMethod = body == nil ? "GET" : "POST"
    if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    let (data, response) = try await E04FixtureHTTP.data(for: request)
    XCTAssertTrue((200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0), path)
    return data
  }
  @MainActor
  private func fixture(named names: MailFixtureNames, token: String) async throws -> MailFixture {
    let providersData = try await api("email/providers", token: token)
    let recipientsData = try await api("email/recipients", token: token)
    let providers = try XCTUnwrap(
      JSONSerialization.jsonObject(with: providersData) as? [[String: Any]])
    let recipients = try XCTUnwrap(
      JSONSerialization.jsonObject(with: recipientsData) as? [[String: Any]])
    let provider = try XCTUnwrap(providers.first { $0["name"] as? String == names.providerName })
    let recipient = try XCTUnwrap(
      recipients.first { $0["email"] as? String == names.recipientAddress })
    return .init(
      providerID: try XCTUnwrap(provider["id"] as? Int), providerName: names.providerName,
      recipientID: try XCTUnwrap(recipient["id"] as? Int), recipientName: names.recipientName,
      recipientAddress: names.recipientAddress)
  }
  @MainActor
  private func assertFixture(_ fixture: MailFixture, token: String, requirePlainSMTP: Bool = true)
    async throws
  {
    let preferencesData = try await api("email/preferences", token: token)
    let preferences = try XCTUnwrap(
      JSONSerialization.jsonObject(with: preferencesData) as? [String: Any])
    XCTAssertEqual(preferences["defaultProviderId"] as? Int, fixture.providerID)
    XCTAssertEqual(preferences["defaultRecipientId"] as? Int, fixture.recipientID)
    let providerData = try await api("email/providers/\(fixture.providerID)", token: token)
    let provider = try XCTUnwrap(JSONSerialization.jsonObject(with: providerData) as? [String: Any])
    XCTAssertEqual(provider["id"] as? Int, fixture.providerID)
    XCTAssertEqual(provider["name"] as? String, fixture.providerName)
    if requirePlainSMTP {
      XCTAssertEqual(provider["auth"] as? Bool, false)
      XCTAssertEqual(provider["startTls"] as? Bool, false)
      XCTAssertEqual(provider["ssl"] as? Bool, false)
      XCTAssertEqual(provider["port"] as? Int, Int(smtpPort))
    }
    let recipientData = try await api("email/recipients/\(fixture.recipientID)", token: token)
    let recipient = try XCTUnwrap(
      JSONSerialization.jsonObject(with: recipientData) as? [String: Any])
    XCTAssertEqual(recipient["id"] as? Int, fixture.recipientID)
    XCTAssertEqual(recipient["name"] as? String, fixture.recipientName)
    XCTAssertEqual(recipient["email"] as? String, fixture.recipientAddress)
    attach(preferencesData, name: "EMAIL-M03-actual-defaults", type: "public.json")
    attach(providerData, name: "EMAIL-M04-actual-provider", type: "public.json")
    attach(recipientData, name: "EMAIL-M03-actual-recipient", type: "public.json")
  }
  @MainActor
  private func setAPIConnection(available: Bool) async throws {
    var request = URLRequest(
      url: try XCTUnwrap(
        URL(string: "\(faultURL)/__faults/annotations/\(available ? "online" : "offline")")))
    request.httpMethod = "POST"
    let (_, response) = try await E04FixtureHTTP.data(for: request)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 204)
  }
  @MainActor
  private func receivedMessages() async throws -> [[String: Any]] {
    let (data, response) = try await E04FixtureHTTP.data(
      from: try XCTUnwrap(URL(string: "\(receiverURL)/messages")))
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
  }
  @MainActor
  private func jobs(token: String) async throws -> [[String: Any]] {
    let data = try await api("email/log?bookId=1&page=0&size=20", token: token)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
  }
  @MainActor
  private func attachmentBytes(_ raw: String) throws -> Data {
    let boundaryPattern = try NSRegularExpression(
      pattern: "boundary=\"([^\"]+)\"", options: .caseInsensitive)
    let match = try XCTUnwrap(
      boundaryPattern.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)))
    let boundary = String(raw[try XCTUnwrap(Range(match.range(at: 1), in: raw))])
    let parts = raw.components(separatedBy: "--\(boundary)").filter {
      $0.lowercased().contains("content-disposition: attachment")
    }
    XCTAssertEqual(parts.count, 1)
    let part = try XCTUnwrap(parts.first)
    let split = try XCTUnwrap(part.range(of: "\r\n\r\n"))
    XCTAssertTrue(
      part[..<split.lowerBound].lowercased().contains("content-transfer-encoding: base64"))
    return try XCTUnwrap(
      Data(base64Encoded: String(part[split.upperBound...]), options: .ignoreUnknownCharacters))
  }
  @MainActor
  private func publishSetup(_ fixture: MailFixture) async throws {
    try await publish(fixture, setupReady: true, expectedStatus: "configured")
  }
  @MainActor
  private func publishDelivery(_ fixture: MailFixture, recoveryEvidence: [String: Any]? = nil)
    async throws
  {
    try await publish(
      fixture, setupReady: true, expectedStatus: "sent", recoveryEvidence: recoveryEvidence)
  }
  @MainActor
  private func publish(
    _ fixture: MailFixture, setupReady: Bool, expectedStatus: String,
    recoveryEvidence: [String: Any]? = nil
  )
    async throws
  {
    let control = try XCTUnwrap(
      ProcessInfo.processInfo.environment["IPAD_E04_RECEIVER_URL"],
      "The same-run receiver must persist native fixture handoff.")
    var request = URLRequest(url: try XCTUnwrap(URL(string: "\(control)/native-handoff")))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    var email: [String: Any] = [
      "providerId": fixture.providerID, "providerName": fixture.providerName,
      "recipientId": fixture.recipientID, "recipientName": fixture.recipientName,
      "recipientAddress": fixture.recipientAddress, "setupReady": setupReady, "bookId": 1,
      "fileId": 1, "expectedStatus": expectedStatus,
    ]
    if let recoveryEvidence { email["recoveryEvidence"] = recoveryEvidence }
    request.httpBody = try JSONSerialization.data(withJSONObject: [
      "testId": "IPAD-E04-A03", "case": "A03", "username": "ipad-owner",
      "email": email,
    ])
    let (_, response) = try await E04FixtureHTTP.data(for: request)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 204)
  }
  @MainActor
  private func sameRunFixture() async throws -> MailFixture {
    let control = try XCTUnwrap(ProcessInfo.processInfo.environment["IPAD_E04_RECEIVER_URL"])
    let (data, response) = try await E04FixtureHTTP.data(
      from: try XCTUnwrap(URL(string: "\(control)/native-handoffs")))
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let handoff = try XCTUnwrap(root["A03"] as? [String: Any])
    let email = try XCTUnwrap(handoff["email"] as? [String: Any])
    XCTAssertEqual(email["setupReady"] as? Bool, true)
    return .init(
      providerID: try XCTUnwrap(email["providerId"] as? Int),
      providerName: try XCTUnwrap(email["providerName"] as? String),
      recipientID: try XCTUnwrap(email["recipientId"] as? Int),
      recipientName: try XCTUnwrap(email["recipientName"] as? String),
      recipientAddress: try XCTUnwrap(email["recipientAddress"] as? String))
  }
  @MainActor
  private func attach(_ data: Data, name: String, type: String) {
    let attachment = XCTAttachment(data: data, uniformTypeIdentifier: type)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

}
