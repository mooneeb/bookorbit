import Foundation

struct ReflowStep {
  let instruction: String
  let check: String
  var action: String? = nil
  var button: String? = nil
}

struct ReflowScenario {
  let id: String
  let title: String
  let aim: String
  let steps: [ReflowStep]
  let question: String
  let success: String

  static let author = ReflowStep(
    instruction:
      "Turn writing OFF. Long-press and select the word useful on this sample. Tap Link selected words. Turn writing ON, mark the word, draw an arrow and handwrite important beside it. All these strokes belong to the selected words. Turn writing OFF; your ink stays visible.",
    check: "I selected words and made my own ink note.")

  static let all: [ReflowScenario] = [
    .init(
      id: "size", title: "Keep a note on a word as text grows",
      aim: "Check whether your mark, arrow and handwriting stay connected to the useful you chose.",
      steps: [
        author,
        .init(
          instruction:
            "Make the text larger. Check the same useful, arrow tip and whole handwritten word.",
          check: "I checked the larger text and ink.", action: "bigger", button: "Make text larger"),
        .init(
          instruction:
            "Make it smaller again. Turn writing OFF and read the paragraph with the ink still visible.",
          check: "I checked the smaller text while reading.", action: "smaller",
          button: "Make text smaller"),
      ],
      question:
        "Did your mark and arrow stay on the chosen useful, with the handwriting readable at both sizes?",
      success: "Yes, the connection stayed clear"),
    .init(
      id: "wrap", title: "Let a marked sentence wrap",
      aim:
        "Check a literal pen mark when one selected sentence becomes several lines. A moving word alone cannot answer this.",
      steps: [
        .init(
          instruction:
            "With writing OFF, select the first whole sentence, then tap Link selected words. Turn writing ON and underline or circle the sentence with the Pencil. Turn writing OFF.",
          check: "I selected a whole sentence and drew my own mark."),
        .init(
          instruction:
            "Narrow the page, then enlarge the text. Check which parts of the literal ink still point at the intended words. The blue range boxes are a reference, not a replacement for your drawing.",
          check: "I checked an actual line wrap.", action: "wrap", button: "Wrap the sentence"),
        .init(
          instruction:
            "Widen the page and reduce the text again. Check whether the original mark and sentence relationship return.",
          check: "I checked the return layout.", action: "unwrap", button: "Return to wider text"),
      ],
      question:
        "Did your literal underline or circle continue to mark the intended sentence after it wrapped?",
      success: "Yes, my literal mark still made sense"),
    .init(
      id: "viewport", title: "Change margins and turn the iPad",
      aim: "Check the same note as the available reading width and orientation change.",
      steps: [
        author,
        .init(
          instruction:
            "Use wider margins. Then physically turn the iPad to the other orientation and back. Check the chosen word and ink each time.",
          check: "I checked wider margins and both orientations.", action: "margins",
          button: "Use wider margins"),
        .init(
          instruction:
            "Try the narrower reading area. Check whether handwriting gets clipped or covers unrelated words.",
          check: "I checked the narrow reading area.", action: "narrow",
          button: "Narrow the reading area"),
      ],
      question:
        "Did the note stay connected, readable and visible through these width and orientation changes?",
      success: "Yes, it stayed readable and connected"),
    .init(
      id: "pages", title: "Read and turn pages with ink enabled",
      aim: "Check finger navigation, Pencil navigation and ink visibility without losing a note.",
      steps: [
        author,
        .init(
          instruction:
            "Turn writing ON. Swipe left with a finger to the next page and right to return. Add a small Pencil mark, then erase and Undo it. Check for accidental turns while drawing.",
          check: "I navigated with a finger while writing was enabled."),
        .init(
          instruction:
            "Turn writing OFF. Navigate with both the Pencil and a finger. Return to your note and check its ink is still visible.",
          check: "I navigated with writing off and checked the saved ink."),
      ],
      question:
        "Did fingers navigate while the Pencil wrote, and did both navigate with writing off while ink stayed visible?",
      success: "Yes, navigation and visible ink worked"),
    .init(
      id: "edit", title: "Edit old ink after the text moves",
      aim: "Check editable old strokes after reflow, rather than a picture of your writing.",
      steps: [
        author,
        .init(
          instruction:
            "Enlarge the text to move the note. Turn writing ON. Erase a small part of the old handwriting and tap Undo. Use the native lasso to move a few strokes, then Undo that too.",
          check: "I edited and restored old strokes after reflow.", action: "bigger",
          button: "Enlarge before editing"),
        .init(
          instruction:
            "Reload the chapter, then turn writing ON again. Check the old strokes still erase and Undo correctly. This experiment starts a new Undo history after a layout change.",
          check: "I checked old editable ink after a chapter reload.", action: "reload",
          button: "Reload the chapter"),
      ],
      question:
        "Could you edit and Undo the old ink in its new position, including after reloading?",
      success: "Yes, old ink remained editable"),
    .init(
      id: "new", title: "Add new ink after a layout change",
      aim: "Check that new strokes stay with the intended note after another reflow.",
      steps: [
        author,
        .init(
          instruction:
            "Enlarge the text. Turn writing ON and add a dot or word to the existing note. Turn writing OFF, select a different useful, and tap Link selected words to start a separate note. Write a different comment there.",
          check: "I added to old ink and created a second note after reflow.", action: "bigger",
          button: "Enlarge before adding ink"),
        .init(
          instruction:
            "Shrink and enlarge the text again. Use Edit next note to inspect both notes. Check that new strokes follow only their own selected words.",
          check: "I checked both notes through another reflow.", action: "cycle",
          button: "Shrink, then enlarge"),
      ],
      question:
        "Did the added strokes and the separate note stay with the words you assigned them to?",
      success: "Yes, each note kept its own words"),
    .init(
      id: "assignment", title: "Choose which repeated word owns the ink",
      aim: "Judge the explicit selection burden when the page contains several useful occurrences.",
      steps: [
        author,
        .init(
          instruction:
            "Turn writing OFF, select another useful and tap Link selected words. Add a different handwritten comment. Use Edit next note to return to the first note and add a small dot to it.",
          check: "I made two explicit associations and returned to edit one."),
        .init(
          instruction:
            "Enlarge the text and check both occurrences. Nothing guesses which comment belongs to which word. Judge whether selecting words and switching notes is comfortable enough for everyday reading.",
          check: "I checked the associations and considered the authoring effort.",
          action: "bigger", button: "Enlarge both notes"),
      ],
      question:
        "Is selecting words first and explicitly switching between ink groups an acceptable way for you to write page notes?",
      success: "Yes, I accept this selection workflow"),
    .init(
      id: "crowding", title: "Keep several handwritten comments readable",
      aim: "Expose collisions instead of silently shrinking or hiding handwriting.",
      steps: [
        author,
        .init(
          instruction:
            "Make two more notes on nearby selected words, each using Link selected words. Write one comment wider than the available margin. Use Edit next note to check each group.",
          check: "I created nearby comments including a wide one."),
        .init(
          instruction:
            "Narrow the reading area and enlarge the text. Inspect every comment for overlap, clipping and covered book text. The experiment reports possible collisions; it does not move notes into a hidden list.",
          check: "I inspected all comments in the crowded layout.", action: "crowd",
          button: "Make the layout crowded"),
      ],
      question:
        "Are all handwritten comments legible and usable in this crowded layout without hiding book text you need?",
      success: "Yes, this crowded layout was usable"),
    .init(
      id: "lifecycle", title: "Keep reflowed ink through reopening and renewal",
      aim:
        "Check that an actual saved, text-linked note survives closing the app and a real signing update.",
      steps: [
        author,
        .init(
          instruction:
            "Enlarge the text. Turn writing ON and add a small new mark to the old note. Turn writing OFF. Fully close the app, temporarily turn internet access off while keeping Bluetooth for the Pencil, and reopen this walkthrough. Check the words and ink, then erase and Undo a mark.",
          check: "I reopened offline and edited both old and new ink.", action: "bigger",
          button: "Enlarge before saving new ink"),
        .init(
          instruction:
            "Restore Wi-Fi and tell the agent this note is ready. Wait for the controlled SideStore update instructions. Keep the existing app installed. After the real update, reopen this walkthrough and check the original words, old and new ink, erase and Undo again.",
          check: "I checked the note after the real signing update."),
      ],
      question:
        "Did the same editable note, including the newly added ink, survive the offline reopen and actual signing update?",
      success: "Yes, the same note and all ink survived"),
  ]
}
