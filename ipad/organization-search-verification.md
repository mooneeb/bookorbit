# Organization native search sizing repair

Issue: #2. Source comparison: `1f2b6dec`.

The organization tester's actual run `run-30295-1791320921117` at `3022fa74` reports that the Authors and Series navigation search fields may clip their text at larger Dynamic Type sizes. Complete audit descriptions `09AFF02E-4300-4FDA-A623-DA0DDA01F13C.txt` and `37CCBE9D-10E4-45BE-9547-EDD9A97E73BD.txt` identify real `UISearchBarTextField` elements with the labels Search authors and Search series and a fixed 540 by 44-point frame.

This repair agent independently read both complete issue descriptions and opened both actual full screenshots (`4FFC4173-EE8D-4419-A1CC-D220B4EF6403.png` and `64698E08-5AE8-4FF9-8F5E-9BB0DF731C11.png`) and their search element crops (`2EA6AB85-28D2-4D0C-8183-4B7493775131.png` and `2708D1CB-268D-4D21-BF29-55EC0CBA98ED.png`). The normal-size placeholders are visible; the full audit reports the larger-text sizing defect. The retained RED is from the cached iOS 26.0 iPad simulator and does not supply physical-device evidence.

The directory body now owns a native `UISearchTextField` whose preferred body font follows the native content-size category. Its proposed height accommodates that font's line height plus vertical padding, with a 44-point minimum. Semantic label and system background colors preserve legibility. The real native search control keeps the same Search authors/Search series accessibility labels and adds the stable `organizationSearch` identifier; its runtime accessibility role still requires confirmation.

Editing updates the existing search binding. The native Search return key commits the current value, dismisses the keyboard and calls the existing directory load action. No server queries, scope checks, filter values or pagination behavior change. The clear button retains native text editing behavior. Existing public search-field locators and all unfiltered audits remain unchanged in this source repair.

Targeted Swift formatting, strict format lint, source parsing, Markdown formatting and `git diff --check` passed. No heavy build or runtime suite was run here because heavy checks are coordinated with the implementing agent and organization tester. The full corrected native and browser tests, larger-text audits, actual screenshots and native role confirmation remain pending. This note records a source repair, not runtime verification.
