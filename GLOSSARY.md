# BookOrbit

A self-hosted book library and reading platform whose readers (web, native apps, Kobo, KOReader) share one library, reading position, and set of annotations.

## Clients

**Official App**:
The upstream BookOrbit iPhone and Apple Watch app distributed on the App Store. Its source is not part of this repository.
_Avoid_: iOS app (ambiguous once an iPad App exists)

**iPad App**:
The native iPad client built in this fork, centered on reading and annotating with Apple Pencil.
_Avoid_: iOS app, tablet app

## Books

**Fixed-layout Book**:
A book whose pages have a fixed geometry that does not reflow, such as a PDF or a comic.
_Avoid_: Paged book

**Reflowable Book**:
A book whose text reflows with font size, margins, and orientation, such as an EPUB.

## Annotations

**Annotation**:
A user's mark on a passage of a book, with a color, a Style, and an optional note, shared across every reader.
_Avoid_: Highlight (a Highlight is one Style of Annotation)

**Style**:
How an Annotation is drawn over its passage: highlight, underline, strikethrough, squiggly, or invert.

**Origin**:
The reader on which an Annotation was created.
_Avoid_: Source (reserved for reading sessions)

**Ink Annotation**:
Freehand Apple Pencil strokes placed at a fixed position on a page of a Fixed-layout Book, kept together with the text recognized from them.
_Avoid_: Drawing, scribble, sketch, handwritten note

**Note**:
Text a user attaches to an Annotation, whether typed or handwritten; handwriting is converted to text and the ink is not kept.
_Avoid_: Comment, text note, handwritten note

**Sketch**:
Apple Pencil ink drawn on its own canvas and attached to an Annotation, shown alongside the passage rather than over the page.
_Avoid_: Sketch note, drawing, Ink Annotation (which sits on the page itself)
