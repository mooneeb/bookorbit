import Foundation

enum Fixture: String {
  case scroll, columns, pdf, missing
}

enum Scenario: String, CaseIterable, Codable {
  case scroll, columns, pdf, offlineEPUB, offlinePDF, missing
  case browserEPUB, browserColumns, browserPDF, replacement, maintenance

  var fixture: Fixture {
    switch self {
    case .columns, .browserColumns: .columns
    case .pdf, .offlinePDF, .browserPDF: .pdf
    case .missing: .missing
    default: .scroll
    }
  }

  var title: String {
    switch self {
    case .scroll: "Check a saved EPUB page"
    case .columns: "Check saved EPUB columns"
    case .pdf: "Check a saved PDF page"
    case .offlineEPUB: "Reopen an EPUB note offline"
    case .offlinePDF: "Reopen a PDF note offline"
    case .missing: "Keep my writing when a page cannot be saved"
    case .browserEPUB: "Read an EPUB note on other devices"
    case .browserColumns: "Read a column EPUB note on other devices"
    case .browserPDF: "Read a PDF note on other devices"
    case .replacement: "Keep a note beside its original words"
    case .maintenance: "Keep a local note through an app update"
    }
  }

  var aim: String {
    switch self {
    case .scroll:
      "Find out whether a saved EPUB page keeps its text, picture and handwriting readable as you zoom in."
    case .columns:
      "Find out whether saving a page with columns preserves the right text, column edges and handwriting."
    case .pdf:
      "Find out whether a saved PDF keeps its words, numbered corners and handwriting in place as you zoom in."
    case .offlineEPUB:
      "Find out whether an EPUB note remains readable and editable after its sample book is removed and the iPad goes offline."
    case .offlinePDF:
      "Find out whether a PDF note remains readable and editable after its sample book is removed and the iPad goes offline."
    case .missing:
      "Find out whether an incomplete page is clearly rejected without losing the handwriting you already made."
    case .browserEPUB, .browserColumns, .browserPDF:
      "Find out whether a saved page and handwriting can be read in Chrome and Vivaldi on your Mac, and Chrome on your Android phone."
    case .replacement:
      "Find out whether your old handwriting stays beside the original sentence when a sample revised sentence has different words."
    case .maintenance:
      "Find out whether an app update or signing refresh preserves a saved page, editable handwriting and a local unsent-note marker."
    }
  }

  var steps: [WalkthroughStep] {
    let write = WalkthroughStep(
      id: "write", title: "Write on this sample page", kind: .write,
      instruction: fixture == .pdf
        ? "Turn writing on. Circle useful, write important beside it, and mark the numbered corners you can see. Then turn writing off. The ink should stay visible."
        : "Turn writing on. Circle useful, draw an arrow into the margin, and write important. Then turn writing off. The ink should stay visible."
    )
    switch self {
    case .scroll, .columns, .pdf:
      return [write]
        + [false, true].flatMap { pdf in
          [1, 2, 4].map { scale in
            let format = pdf ? "PDF copy" : "Page image"
            return WalkthroughStep(
              id: "\(pdf ? "pdf" : "image")-\(scale)",
              title: "Check \(format.lowercased()) at \(scale)x",
              kind: .view(pdf: pdf, scale: scale),
              instruction:
                "This is your saved page, shown as a \(format.lowercased()) at \(scale)x. \(scale > 1 ? "Drag with a finger to inspect the enlarged page." : "Look across the whole saved page.") Both formats keep the handwriting separately editable.",
              checks: [
                fixture == .pdf
                  ? "I tried reading useful and inspecting the visible numbered corners and page edges."
                  : "I tried reading useful and inspecting the leaf picture, margins and \(fixture == .columns ? "column edges" : "nearby text").",
                "I checked that my circle, arrow or comment still lines up with what I marked.",
              ],
              question:
                "At \(scale)x, is this \(format.lowercased()) readable with the ink in the right place?",
              answers: [
                "Yes, it is readable and aligned", "No, I see a problem",
                "I cannot judge this view",
              ])
          }
        }
    case .offlineEPUB, .offlinePDF:
      return [
        write,
        WalkthroughStep(
          id: "remove", title: "Remove only this sample book", kind: .remove,
          instruction:
            "Your page and handwriting have been saved. Next, remove this walkthrough's sample book. The saved page and ink will be kept. Your real books are never involved."
        ),
        WalkthroughStep(
          id: "offline", title: "Close the app and reopen it offline", kind: .offline,
          instruction:
            "Fully close this app in the iPad app switcher. Turn off Wi-Fi and cellular data if present, leaving Bluetooth on for the Pencil. Reopen Orbit Context PROTOTYPE. It should return to this step with your saved page and ink. Do not uninstall the app.",
          checks: [
            "I tried fully closing the app and reopening it with internet off.",
            "I looked for the original words and my handwriting.",
          ],
          question: "Did the saved page and your handwriting return offline?",
          answers: [
            "Yes, both returned", "No, something is missing or changed",
            "I could not complete the offline check",
          ]),
        WalkthroughStep(
          id: "edit", title: "Edit the recovered handwriting", kind: .edit,
          instruction:
            "Keep internet off. Turn writing on, erase a small part of your mark, then use the Pencil toolbar's Undo. Add a small mark and turn writing off. The page and ink should remain visible.",
          checks: [
            "I tried erasing a mark and Undo.", "I tried adding ink, then turned writing off.",
          ],
          question: "Could you edit the recovered ink and keep it visible?",
          answers: [
            "Yes, erase, Undo and new ink worked", "No, editing or visibility failed",
            "I could not try the editing check",
          ]),
      ]
    case .missing:
      return [
        write,
        WalkthroughStep(
          id: "failure", title: "Check the failed save and recover your writing", kind: .failure,
          instruction:
            "This sample deliberately has a missing picture. Saving should show a clear explanation and keep your ink. Tap Reopen this sample, then check that your mark is still here. It should not claim to have saved a complete page.",
          checks: [
            "I looked for an explanation of why the page could not be saved.",
            "I tapped Reopen this sample and checked my handwriting.",
          ],
          question: "Was the failed save explained, and was your handwriting kept?",
          answers: [
            "Yes, the explanation was clear and ink was kept",
            "The message was unclear or ink was lost", "I could not complete this check",
          ]),
      ]
    case .browserEPUB, .browserColumns, .browserPDF:
      return [
        write,
        WalkthroughStep(
          id: "share", title: "Send this saved page to your other devices", kind: .share,
          instruction:
            "Tap Share saved page. Send the HTML file to your Mac and Android phone using your usual file-transfer method. That single file includes the saved page, current handwriting and original sentence. This is a saved-note preview; it does not connect to your BookOrbit website.",
          checks: ["I tried sending the saved HTML file to my Mac and phone."],
          question: "Is the file available on both devices?",
          answers: ["Yes, it is ready on both", "I could not transfer or find the file"]),
      ]
        + ["Chrome on your Mac", "Vivaldi on your Mac", "Chrome on your Android phone"].enumerated()
        .map { index, browser in
          WalkthroughStep(
            id: "browser-\(index)", title: "Read the saved note in \(browser)", kind: .browser,
            instruction:
              "Open the HTML file in \(browser). It shows Page image and PDF copy with your ink, then Original sentence. Enlarge each preview and check the marked word. You are viewing ink here, not editing strokes.",
            checks: [
              "I tried opening both previews and checking their words, picture or page corners, and ink.",
              "I looked for Original sentence and tried comparing it with the sentence I marked.",
            ],
            question: "In \(browser), can you read the page and ink in both previews?",
            answers: [
              "Yes, both previews are readable and aligned",
              "No, one or both previews have a problem", "I could not open or check the file",
            ],
            commentPrompt:
              "Record the browser version and any problem. On Android, include the Chrome version.")
        }
    case .replacement:
      return [
        write,
        WalkthroughStep(
          id: "quote", title: "Compare the original note with a revised page", kind: .quote,
          instruction:
            "Tap Compare original and revised pages. On the left, find useful and your handwriting on the saved original page. On the right, find revised on a new sample page. Your old ink should stay on the original, without moving to the revised page. Return here to answer. This is a local sample revision, not an import of a complete new book.",
          checks: [
            "I saw my original page and handwriting beside the revised sample page.",
            "I checked that the saved page and ink still show the original words.",
          ],
          question: "Did your note stay beside the original words without moving automatically?",
          answers: [
            "Yes, the original page and ink stayed together",
            "No, the original context or ink changed", "I could not compare the sentences",
          ]),
      ]
    case .maintenance:
      return [
        write,
        WalkthroughStep(
          id: "maintenance", title: "Reopen this note after an update or refresh",
          kind: .maintenance,
          instruction:
            "This walkthrough has saved its own page, ink and a local unsent-note marker. Leave them here while we perform an in-place app update or signing refresh. Reopen the app afterwards without uninstalling it. Then erase a small mark, Undo it, and check the original sentence. This step waits for the installation check with me.",
          checks: [
            "An app update or signing refresh was completed without uninstalling.",
            "I reopened this note and tried erase and Undo.",
            "I checked the original sentence and local marker below.",
          ],
          question:
            "After the update or refresh, were the page, editable ink and local marker kept?",
          answers: [
            "Yes, everything was kept and editing works",
            "No, something was lost or cannot be edited",
            "The update or refresh has not been checked yet",
          ]),
      ]
    }
  }
}

enum StepKind {
  case write
  case view(pdf: Bool, scale: Int)
  case remove, offline, edit, failure, share, browser, quote, maintenance
}

struct WalkthroughStep {
  var id: String
  var title: String
  var kind: StepKind
  var instruction: String
  var checks: [String] = []
  var question = ""
  var answers: [String] = []
  var commentPrompt = "Optional: describe exactly what looked wrong or was unclear."
}

struct WalkthroughReview: Codable {
  var stepIndex = 0
  var finished = false
  var checks: [String: [Bool]] = [:]
  var answers: [String: String] = [:]
  var comments: [String: String] = [:]
  var actions: [String: Bool] = [:]
  var lastMessage = ""
}

extension ScratchStore {
  func readWalkthrough() throws -> WalkthroughReview {
    let url = retained.appending(path: "walkthrough.json")
    guard FileManager.default.fileExists(atPath: url.path) else { return WalkthroughReview() }
    return try JSONDecoder().decode(WalkthroughReview.self, from: Data(contentsOf: url))
  }

  func writeWalkthrough(_ review: WalkthroughReview) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try write(encoder.encode(review), "walkthrough.json")
  }
}
