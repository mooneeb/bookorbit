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
  var chapter: Int? = nil
  var markKind: String? = nil
  var answers: [String]? = nil
  var gapReflow: Bool { id == "underline-gap-reflow" }
  var localEditing: Bool { id.hasSuffix("-local-edit") || gapReflow }

  static func localEdit(_ kind: String) -> ReflowScenario {
    let underline = kind == "underline"
    let mark = underline ? "an underline" : "a circle or oval"
    return .init(
      id: kind + "-local-edit",
      title: underline ? "Erase only one line of an underline" : "Erase only one line of a circle",
      aim:
        "Check that erasing one line leaves the other line unchanged, including through Undo, Redo and a chapter reload. Further text resizing is a separate test.",
      steps: [
        .init(
          instruction:
            "Keep the iPad in this orientation for this walkthrough. With writing OFF, select the first whole sentence and tap Link selected words. Turn writing ON and draw only \(mark) marking that sentence. Turn writing OFF. This walkthrough starts fresh and needs no earlier note.",
          check: "I selected the sentence and drew my own \(underline ? "underline" : "outline")."),
        .init(
          instruction:
            "Tap Wrap and prepare editable lines. You should see one copy of your mark per line. Line 1 is selected for editing. Turn writing ON, choose the native pixel eraser, and erase a small gap in line 1's mark. Turn writing OFF. Check that line 2's mark has no matching gap. All marks stay visible.",
          check: "I erased a gap on line 1 and checked that line 2 was unchanged.",
          action: "local-prepare", button: "Wrap and prepare editable lines"),
        .init(
          instruction:
            "Stay on line 1. Tap Undo: the gap should close. Tap Redo: the same gap should return only on line 1. Leave that gap visible for the remaining steps.",
          check: "Undo closed the gap; Redo restored it only on line 1."),
        .init(
          instruction:
            "Tap Edit next line until line 2 is selected. Turn writing ON, erase a small part of line 2's mark, then Undo that edit. Turn writing OFF. Line 2 should be whole again, while line 1 keeps its earlier gap. Switching lines starts a fresh Undo history.",
          check: "I edited and restored line 2 without changing line 1's gap."),
        .init(
          instruction:
            "Reload this chapter. Check that line 1 still has its gap and line 2 is still whole. Use Edit next line to choose line 1, turn writing ON, erase another small part, then Undo. The newly erased part should return; the earlier saved gap should remain. Turn writing OFF. Reloading starts a fresh Undo history.",
          check: "Both marks kept their own state after reload and remained editable.",
          action: "local-reload", button: "Reload and check the saved marks"),
      ],
      question:
        "Did each line keep its own edits, with Undo and Redo working and the saved gap surviving the chapter reload?",
      success: "Yes, edits stayed on their own line", chapter: 1, markKind: kind,
      answers: [
        "Yes, edits stayed on their own line", "No, another line changed or editing failed",
        "I could not complete this check",
      ])
  }

  static let author = ReflowStep(
    instruction:
      "Turn writing OFF. Long-press and select the word useful on this sample. Tap Link selected words. Turn writing ON, mark the word, draw an arrow and handwrite important beside it. All these strokes belong to the selected words. Turn writing OFF; your ink stays visible.",
    check: "I selected words and made my own ink note.")

  static let all: [ReflowScenario] =
    [
      .init(
        id: "size", title: "Keep a note on a word as text grows",
        aim:
          "Check whether your mark, arrow and handwriting stay connected to the useful you chose.",
        steps: [
          author,
          .init(
            instruction:
              "Make the text larger. Check the same useful, arrow tip and whole handwritten word.",
            check: "I checked the larger text and ink.", action: "bigger",
            button: "Make text larger"),
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
        aim:
          "Judge the explicit selection burden when the page contains several useful occurrences.",
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
      .init(
        id: "underline-compare", title: "Compare underlines when a sentence wraps",
        aim:
          "Compare the shape of your own underline before choosing a wrapping rule. This checks appearance; editing the adapted copies is a later test.",
        steps: [
          .init(
            instruction:
              "With writing OFF, select the first whole sentence and tap Link selected words. Turn writing ON and draw only an underline beneath that sentence. Turn writing OFF. This walkthrough treats all of your strokes as that underline; add no handwriting or arrows.",
            check: "I selected the sentence and drew my own underline."),
          .init(
            instruction:
              "Wrap the sentence. This first view keeps your original pen shape together. Check which words it now underlines.",
            check: "I checked the original shape in the wrapped layout.", action: "mark-original",
            button: "Wrap and show original shape"),
          .init(
            instruction:
              "Show one copy of your underline beneath each new line of selected words. Each copy is stretched to that line. Compare the style, thickness and which words are marked. These are native-rendered copies of your mark, not a replacement typed underline.",
            check: "I checked the underline copied beneath each line.", action: "mark-per-line",
            button: "Show an underline beneath each line"),
          .init(
            instruction:
              "Return to the original reading layout. Your original ink is still editable: turn writing ON, erase a small part, then Undo. Turn writing OFF. The final screen lets you compare both wrapped views again before answering.",
            check: "I checked that my original mark was kept and remains editable.",
            action: "mark-restore", button: "Return to original layout and ink"),
        ],
        question: "Which underline appearance should we investigate further when a sentence wraps?",
        success: "Follow each line with a reshaped copy", chapter: 1, markKind: "underline",
        answers: [
          "Follow each line with a reshaped copy", "Keep the single original shape",
          "Neither appearance works for me", "I could not judge these appearances",
        ]),
      .init(
        id: "circle-compare", title: "Compare circles when a sentence wraps",
        aim:
          "Compare separate circles per line with one outline around the whole wrapped sentence, using your own Pencil circle. Editing the adapted copies is a later test.",
        steps: [
          .init(
            instruction:
              "With writing OFF, select the first whole sentence and tap Link selected words. Turn writing ON and draw only a circle or oval around that sentence. Turn writing OFF. This walkthrough treats all of your strokes as that outline; add no handwriting or arrows.",
            check: "I selected the sentence and drew my own outline."),
          .init(
            instruction:
              "Wrap the sentence. This view keeps your original outline together. Check which words it now surrounds.",
            check: "I checked the original outline in the wrapped layout.", action: "mark-original",
            button: "Wrap and show original outline"),
          .init(
            instruction:
              "Show a reshaped copy of your outline around each line's selected words. Check the covered words, the gaps between outlines, and changes to your pen shape or thickness.",
            check: "I checked separate outlines around each line.", action: "mark-per-line",
            button: "Show an outline around each line"),
          .init(
            instruction:
              "Show one reshaped copy around the full area occupied by the wrapped sentence. Check whether it includes unrelated words or leaves selected words outside. Compare it with the separate outlines you just saw.",
            check: "I checked one outline around the whole wrapped sentence.",
            action: "mark-enclosing", button: "Show one outline around the sentence"),
          .init(
            instruction:
              "Show neat outlines around each line instead. These are newly drawn rounded outlines using your first stroke's ink and a regular thickness, rather than copies of your hand-drawn shape or pressure. Compare readability and whether losing the irregular shape is acceptable. Your original drawing stays saved.",
            check: "I compared neat outlines with the copied hand-drawn outlines.",
            action: "mark-neat",
            button: "Show neat outlines around each line"),
          .init(
            instruction:
              "Return to the original reading layout. Turn writing ON, erase a small part of your original outline, then Undo. Turn writing OFF. The final screen lets you compare all four wrapped views again before answering.",
            check: "I checked that my original outline was kept and remains editable.",
            action: "mark-restore", button: "Return to original layout and ink"),
        ],
        question: "Which circle appearance should we investigate further when a sentence wraps?",
        success: "Separate outlines around each line", chapter: 1, markKind: "circle",
        answers: [
          "Separate copies around each line", "Neat outlines around each line",
          "One outline around the whole sentence",
          "Keep the single original shape", "None of these appearances works for me",
          "I could not judge these appearances",
        ]),
    ] + [
      localEdit("underline"), localEdit("circle"),
      .init(
        id: "underline-gap-reflow", title: "Keep an erased underline gap with its word",
        aim:
          "Erase below useful, change the line breaks, then check that the gap still belongs to useful and the underline remains editable.",
        steps: [
          .init(
            instruction:
              "With writing OFF, select the first whole sentence and tap Link selected words. Turn writing ON and draw only an underline beneath the sentence. Turn writing OFF. This walkthrough starts with its own fresh note.",
            check: "I selected the first sentence and drew my own underline."),
          .init(
            instruction:
              "Prepare the wrapped underline. Turn writing ON and use the native pixel eraser to make a small gap directly below useful on the first line. Turn writing OFF. Remember which letters are above your gap.",
            check: "I erased a small gap below useful and checked its position.",
            action: "local-prepare", button: "Prepare the wrapped underline"),
          .init(
            instruction:
              "Widen the text. Look at useful in its new position: the same gap should still be beneath the same letters. Check the rest of the underline too, including where the old lines join. Report extra gaps, broken joins or shifted marks.",
            check: "I checked the gap and the rest of the underline in wider text.",
            action: "gap-wide", button: "Widen the text and follow the gap"),
          .init(
            instruction:
              "Make the text larger again. The line breaks may change. Check that your gap still belongs to useful and that other words have not gained the same gap.",
            check: "I checked the gap through another text-size change.", action: "gap-large",
            button: "Make text larger and follow the gap"),
          .init(
            instruction:
              "All the displayed underline is now editable together. Turn writing ON, erase a small part below another word, then Undo. That part should return while the earlier gap below useful stays. Turn writing OFF. A layout change starts a fresh Undo history.",
            check: "I edited and restored the moved underline without closing the original gap."),
          .init(
            instruction:
              "Reload the saved underline and chapter. Check useful and its gap again. Turn writing ON, erase a small part and Undo it. The saved gap should stay, and the new erasure should be undone. Turn writing OFF.",
            check: "The saved gap survived reloading and the underline remained editable.",
            action: "gap-reload", button: "Reload the edited underline"),
        ],
        question:
          "Did your erased gap follow useful through both layouts, with the rest of the underline readable and still editable after reload?",
        success: "Yes, the gap followed its word and editing worked", chapter: 1,
        markKind: "underline",
        answers: [
          "Yes, the gap followed its word and editing worked",
          "No, a gap or mark moved incorrectly", "I could not complete this walkthrough",
        ]),
    ]
}
