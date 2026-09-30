# The iPad App is a full native port of the web app

The iPad App reimplements every screen of the web app natively in SwiftUI rather than embedding web pages for the less-used screens (settings, admin, tools). The source of the Official App is not available, so nothing could be reused from it, and native screens throughout give the iPad App consistent Apple Pencil, keyboard, and multitasking behavior. The one exception: when a merge from upstream adds a web screen that has not been ported yet, the iPad App shows that screen in an in-app web view until a native version exists.

## Considered Options

- Native reading screens, with the other screens embedded as web pages: rejected because the user wants the whole app to be native.
- The whole web app in a web view, with only the reader native: rejected for the same reason.

## Consequences

Every upstream release that adds or changes web screens creates native porting work. A parity checklist generated from the web app's routes tracks which screens are still missing after each upstream merge.
