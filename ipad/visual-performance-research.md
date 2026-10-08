# Native visual and performance research

Research date: 2026-10-06. This is a runnable proposal based on primary Apple documentation, installed Apple tool help/SDK headers and local source. No UI test, setting change, screenshot comparison, baseline creation or performance measurement was performed. No SDK, runtime, dependency or voice was downloaded. The agreed boundaries remain native UI, web UI, public authenticated HTTP and delivered files. The required representative matrix and human baseline review remain acceptance work, not conclusions from this report. [Required verification](../docs/ipad/tracer-tickets.md#required-automated-testing), [specification](../docs/ipad/specification.md), [physical proof ticket](../docs/ipad/tickets.md#ipad-05), [local-rendering decision](../docs/adr/0004-allow-local-epub-rendering-in-the-native-reader.md).

## Installed tools and bounded configuration

Read-only inventory found macOS 27.0, arm64, Xcode 27.0 (`27A266a`) and available cached iOS 26.0 runtime (`23A343`). These are different version axes: using the Xcode 27 SDK does not require downloading an iPadOS 27 runtime. Existing devices provide both required Pro sizes:

| Existing simulator                       | UDID                                   | Role                                                                                                 |
| ---------------------------------------- | -------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| BookOrbit Test iPad, Pro 13-inch M4 16GB | `BFC78674-A5BF-45C1-86AC-7AE96627A0E7` | Preserve the current native gate's model and runtime.                                                |
| Pro 11-inch M5 12GB                      | `2D308564-4246-4C75-B67B-DCFC2AD4BE7B` | Second representative size, already created on the same runtime.                                     |
| Pro 13-inch M5 12GB                      | `DAC90D1E-5E78-46A7-A87C-023F9351FBD9` | Optional alternative if both size baselines should use M5; keep model-specific comparisons separate. |

Sources: `xcodebuild -version`, `sw_vers -productVersion`, `uname -m`, filtered `xcrun simctl list runtimes/devices/devicetypes --json`. Simulator model RAM labels do not constrain the Mac process like physical device memory. Verify inventory again at execution time and run devices serially, since the current harness uses fixed local server ports. [Harness](../scripts/ipad/run-harness.mjs), [native targets](project.yml).

The installed `simctl help ui` supports `appearance light/dark`, `content_size` standard and accessibility categories, and `increase_contrast enabled/disabled`. It has no documented Reduce Motion option. `simctl help status_bar` supports time, network/Wi-Fi and battery overrides; `help io` supports PNG screenshots and bounded video recordings. Use an explicit device UDID rather than `booted`, which can choose one of multiple booted devices. These commands are proposed for a later run, and have not been executed here:

```sh
BO_VISUAL_DEVICE=BFC78674-A5BF-45C1-86AC-7AE96627A0E7
xcrun simctl status_bar "$BO_VISUAL_DEVICE" list
xcrun simctl ui "$BO_VISUAL_DEVICE" appearance
xcrun simctl ui "$BO_VISUAL_DEVICE" content_size
xcrun simctl ui "$BO_VISUAL_DEVICE" increase_contrast

xcrun simctl status_bar "$BO_VISUAL_DEVICE" override --time '09:41' --dataNetwork wifi --wifiMode active --wifiBars 3 --batteryState charged --batteryLevel 100
xcrun simctl ui "$BO_VISUAL_DEVICE" appearance light
xcrun simctl ui "$BO_VISUAL_DEVICE" content_size large
xcrun simctl ui "$BO_VISUAL_DEVICE" increase_contrast disabled

IPAD_TEST_DESTINATION="platform=iOS Simulator,id=$BO_VISUAL_DEVICE" \
IPAD_TEST_ONLY=BookOrbitUITests/EntryJourneyTests/testIPADE01A02EditMetadataAndReopen \
pnpm ipad:test:ui
```

The selected device must be booted before setting these options. At execution, record its previous options and status overrides, then restore those values afterward; clearing an existing override is not equivalent to restoring it. The example selector exists in the inspected [EntryJourneyTests.swift](UITests/EntryJourneyTests.swift); omit it to run the current suite or substitute another verified method. Existing selectors do not implement the entire matrix or performance cases proposed below. Use `content_size accessibility-extra-large` for the stress row; do not call standard `large` an accessibility-size check.

Pin English/en_US with the existing launch arguments, runtime/build, exact font resources, fixture bytes/checksums, dates, account time zone and network fault/delay recipe. Pin orientation through `XCUIDevice.shared.orientation`, then assert actual screenshot/window geometry. The status-bar clock override does not freeze the app's `Date()` or relative-date text. Dismiss keyboard/caret focus for states that do not specifically test editing. Keep animations enabled for normal-motion rows. [Current launch/capture helper](UITests/EntryJourneyTests.swift), [current fixture/harness](../scripts/ipad/http.test.mjs), [browser's separate configuration](../scripts/ipad/playwright.config.mjs).

## Genuine Reduce Motion and a real narrow window

Use Settings > Accessibility > Motion > Reduce Motion. Apple also documents Accessibility Inspector's Settings pane as a supported way to toggle system-wide accessibility settings. Both are genuine system configuration; private defaults keys, disabled UIKit animations, app-only SwiftUI environment overrides or browser reduced-motion emulation do not establish this native requirement. Public UIKit `UIAccessibility.isReduceMotionEnabled` and SwiftUI `accessibilityReduceMotion` read the preference; neither is a system setter. [Settings path](https://support.apple.com/en-us/111781), [Accessibility Inspector settings](https://developer.apple.com/documentation/accessibility/testing-system-accessibility-features-in-your-app), [UIKit read API](https://developer.apple.com/documentation/uikit/uiaccessibility/isreducemotionenabled), [SwiftUI environment](https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilityreducemotion).

For an automated run, create `XCUIApplication(bundleIdentifier:"com.apple.Preferences")`, navigate actual accessible Settings controls, check the switch's value, change it only if necessary and capture that system state. The installed runtime identifies its Settings app as `com.apple.Preferences`, confirmed with read-only `simctl appinfo`. Use the public application initializer to launch an installed system app. Return to BookOrbit with `activate()`, perform the same reader/navigation action and assert the usable nonanimated destination and logical anchor. Record/restore the original switch value through Settings. Record the runtime's actual row/query hierarchy rather than assuming phone cell structure on iPad; if it cannot be driven reliably, use the documented Inspector UI and retain that setup as a concrete manual limitation. [Application initializer](<https://developer.apple.com/documentation/xcuiautomation/xcuiapplication/init(bundleidentifier:)>), [native accessibility source](/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk/System/Library/Frameworks/UIKit.framework/Headers/UIAccessibility.h:566).

For narrow layout, select Windowed Apps in Settings > Multitasking & Gestures, then drag the system's window corner or bottom-right resize handle. XCUITest exposes coordinate dragging; calculate the gesture from the current window frame, await a settled smaller frame and assert that the required controls remain reachable. Record the actual supported width/height in points and screenshot pixels, then reuse that geometry within a documented tolerance. The smallest accepted system size must be observed; this research does not prescribe an untested minimum width. Return to full screen using system window controls. [Apple windowing instructions](https://support.apple.com/en-us/125309), [iPadOS 26 window design](https://developer.apple.com/videos/play/wwdc2025/208/?time=298), [coordinate gesture source](/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/Library/Frameworks/XCUIAutomation.framework/Headers/XCUICoordinate.h:44).

The installed iOS geometry-preferences API expresses orientation, not an arbitrary target CGRect; scene size restrictions express preferences that system limits can override. `simctl io screenConfig geometry` changes a screen mode, not a multitasking app window. Cropping a full-screen capture or forcing a narrow content frame also does not prove actual window resizing, safe areas, collapsed navigation or system-window-control placement. Those paths cannot silently stand in for the narrow-window row. [iOS geometry header](/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk/System/Library/Frameworks/UIKit.framework/Headers/UIWindowSceneGeometryPreferencesIOS.h), [size restrictions header](/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk/System/Library/Frameworks/UIKit.framework/Headers/UISceneSizeRestrictions.h), [Apple resizing guidance](https://developer.apple.com/documentation/technotes/tn3192-migrating-your-app-from-the-deprecated-uirequiresfullscreen-key).

## Small representative visual matrix

Start with nine configurations instead of all Cartesian combinations. Each adds a specific stress condition. Fullscreen dimensions and narrow dimensions must be recorded from the actual run.

| Row | Pro size | Orientation/window | Theme/type                      | Reduce Motion | Representative states                                                                                 |
| --- | -------- | ------------------ | ------------------------------- | ------------- | ----------------------------------------------------------------------------------------------------- |
| V1  | 13       | Portrait/full      | Light/default                   | Off           | Library/list/grid, search, long-title detail, metadata editor, error, reader first/next/resumed page. |
| V2  | 11       | Portrait/full      | Light/default                   | Off           | Same core states at smaller size; title/control reachability.                                         |
| V3  | 13       | Landscape/full     | Dark/default                    | Off           | Sidebar, search/detail, reader/tool controls and popover placement.                                   |
| V4  | 11       | Landscape/full     | Light/accessibility-extra-large | Off           | Library, detail, metadata/validation, reader controls and keyboard alternatives.                      |
| V5  | 13       | Portrait/full      | Dark/accessibility-extra-large  | Off           | Long Unicode text, metadata lock/error, menus and reader controls.                                    |
| V6  | 13       | Landscape/narrow   | Light/default                   | Off           | Actual collapsed navigation, sheet/editor, reader destination and preserved anchor.                   |
| V7  | 11       | Landscape/narrow   | Dark/accessibility-extra-large  | Off           | Most constrained control layout, editor/popover clipping and anchor preservation.                     |
| V8  | 13       | Portrait/full      | Light/default                   | On            | Usable nonanimated page movement and navigation with same destination.                                |
| V9  | 11       | Landscape/narrow   | Dark/default                    | On            | Narrow reduced-motion reading and menu/control alternatives.                                          |

Associate each capture with the applicable existing QA ID, named test, state and configuration, including denied-permission and controlled failure states. For currently implemented work, start with catalog/metadata plus the separate PDF proof. Expand the same matrix to EPUB modes/selection, comics, audio, Read Along and TTS as those real screens become available. A PDF proof snapshot does not provide missing ebook/curl/narration coverage. Notes, selection/tools and conflict states must use the owning ticket's actual implemented UI. Keep the known Unicode passage oracle for reader anchor assertions. [QA/matrix requirements](../docs/ipad/tracer-tickets.md), [reader oracle research](reader-feasibility-research.md), [existing separate PDF journey](ReaderProof/UITests/PDFReaderProofTests.swift).

Use observable readiness assertions before capture: completed title/metadata values, visible and hittable controls, expected page/passage, loading/error transition completion and settled window frame. Preserve a full `XCUIScreen.main.screenshot()` attachment with `.keepAlways`; an optional application/window crop is supplementary. Full-screen captures retain safe areas and window context. Do not replace title geometry assertions with navigation-bar background geometry. [Apple screen capture API](https://developer.apple.com/documentation/xcuiautomation/xcuiscreen), [current capture helper](UITests/EntryJourneyTests.swift), [existing artifact limitations](verification.md).

Pillow 12.3.0 is already installed in the active Python 3.12.12 environment; `magick`/ImageMagick `compare`, NumPy, OpenCV and scikit-image were not found. macOS `sips` can inspect/convert images, but it is not a regression comparator. A bounded one-pair Pillow comparator needs no install. This proposed snippet creates comparison artifacts only when later invoked with an already human-approved expected PNG; a missing baseline fails without generating or accepting one:

```python
import json
import shutil
import sys
from pathlib import Path
from PIL import Image, ImageChops, ImageStat

expected_path, actual_path, output_path = map(Path, sys.argv[1:4])
if not expected_path.is_file():
    raise SystemExit("Missing human-approved baseline")
output_path.mkdir(parents=True, exist_ok=True)
shutil.copyfile(expected_path, output_path / "expected.png")
shutil.copyfile(actual_path, output_path / "actual.png")
with Image.open(expected_path) as source:
    expected = source.convert("RGB")
with Image.open(actual_path) as source:
    actual = source.convert("RGB")
if expected.size != actual.size:
    raise SystemExit("Image dimensions differ; inspect retained expected/actual")
diff = ImageChops.difference(expected, actual)
red, green, blue = diff.split()
maximum = ImageChops.lighter(ImageChops.lighter(red, green), blue)
changed = sum(maximum.histogram()[1:])
diff.save(output_path / "diff.png")
diff.point(lambda value: min(255, value * 8)).save(output_path / "diff-visible.png")
report = {
    "changedPixels": changed,
    "totalPixels": expected.width * expected.height,
    "bounds": maximum.getbbox(),
    "channelRMS": ImageStat.Stat(diff).rms,
}
(output_path / "comparison.json").write_text(json.dumps(report, indent=2))
raise SystemExit(1 if changed else 0)
```

RGB conversion avoids an RGBA diff's zero alpha hiding RGB changes when calling `getbbox()` with its default alpha behavior. This strict comparator is a starting proposal, not an approved tolerance. Review any antialias/font/color-profile variance and establish a fixed per-configuration policy before accepting results; do not add a broad percentage threshold to conceal moved/missing text. Record any narrowly justified mask, retain unmasked originals, and never mask meaningful reader/control/selection pixels. Human review must approve expected captures; the agent inspects expected/actual/diff and fixes regressions, but cannot auto-accept a baseline. [Primary Pillow operations](https://pillow.readthedocs.io/en/stable/reference/ImageChops.html#PIL.ImageChops.difference), [installed getbbox source](/Users/moon/.pyenv/versions/3.12.12/lib/python3.12/site-packages/PIL/Image.py), [baseline requirement](../docs/ipad/tracer-tickets.md#required-test-approach).

## XCTest metrics that match the interaction

Installed `XCTMetric.h`, `XCTMetric+UIAutomation.h` and `XCTMeasureOptions.h` declare the following APIs. CPU/memory metrics must target `application:app`, because their default constructor targets the current process, which is not automatically the app under UI test. The hitch metric requires its application constructor; `XCTHitchMetric(application:)` is available from iOS 26 in this SDK/cached runtime pair.

| Interaction                   | Actual metric/proof path                                                                                                                                                                                                                     | Limits                                                                                                                                                                                                   |
| ----------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Process launch                | `XCTApplicationLaunchMetric(waitUntilResponsive:true)` around terminate/launch iterations; separately await the loaded authenticated library.                                                                                                | Measures first frame/main-thread responsiveness, not network-loaded catalog readiness. Repeated process launches do not prove uncached physical cold launch.                                             |
| Navigation                    | `XCTOSSignpostMetric.navigationTransitionMetric` for emitting native navigation transitions; `customNavigationTransitionMetric` for supported custom navigation intervals. Combine elapsed clock/hitches with visible destination assertion. | Current book detail is a sheet. Neither that presentation nor UIKit page curl is guaranteed to emit a built-in navigation interval. Require actual exported samples.                                     |
| Library scrolling             | `XCTOSSignpostMetric.scrollingAndDecelerationMetric`, `XCTHitchMetric(application:app)`, clock and app-targeted memory; fixed swipe velocity, actual scroll and settled content assertions.                                                  | Timing must exclude login/setup and unrelated navigation. Empty animation samples are missing evidence, not zero hitches.                                                                                |
| Reader page turn              | `XCTClockMetric()` plus `XCTHitchMetric(application:app)` around a real completed swipe/turn and visible known passage/page. Test cancellation separately.                                                                                   | No dedicated built-in page-curl metric is declared. A custom named OS signpost can narrow renderer begin/end timing later, but does not replace UI gestures, destination or CFI assertions.              |
| Large-library work/open-close | Clock, `XCTCPUMetric(application:app)`, `XCTMemoryMetric(application:app)` around bounded public search/pagination and repeated reader open/close.                                                                                           | Preserve actual metric identifiers/units and peak/growth values exported. Memory delta alone does not establish a peak budget, server memory, renderer child-process memory or physical jetsam behavior. |

Sources: [installed metrics](/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/Library/Frameworks/XCTest.framework/Headers/XCTMetric.h:210), [app-targeted constructors](/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/Library/Frameworks/XCTest.framework/Headers/XCTMetric+UIAutomation.h), [launch definition](<https://developer.apple.com/documentation/xctest/xctapplicationlaunchmetric/init(waituntilresponsive:)>), [navigation](https://developer.apple.com/documentation/xctest/xctossignpostmetric/navigationtransitionmetric), [scrolling](https://developer.apple.com/documentation/xctest/xctossignpostmetric/scrollinganddecelerationmetric), [hitch metric](https://developer.apple.com/documentation/xctest/xcthitchmetric), [memory/peak guidance](https://developer.apple.com/documentation/xcode/preventing-memory-use-regressions), [current modal source](Sources/Library/LibraryView.swift).

The smallest separate performance suite needs launch, catalog search/pagination, library scrolling, reader open/close and page-turn methods, with deterministic fixture restoration outside each measured interval. Use Release configuration and a performance test plan without debugger, as Apple recommends; the current functional harness's timings/configuration are not those measurements. Five retained iterations plus one discarded warm-up is the installed default. Record sample count, average, standard deviation and range; do not report a credible tail percentile from only five samples. An initial run without a reviewed baseline is profiling, not a passed performance budget. [Apple performance setup/baselines](https://developer.apple.com/documentation/xcode/writing-and-running-performance-tests), [iteration semantics](https://developer.apple.com/documentation/xctest/xctmeasureoptions/iterationcount), [installed measurement options](/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/Library/Frameworks/XCTest.framework/Headers/XCTMeasureOptions.h).

For a page turn, the future test can use this shape. Helpers must drive the actual UI; fixture state and assertions use the agreed public boundaries. UI automation/polling cost is included in elapsed time, so label it as an end-to-end automated transition measurement:

```swift
let options = XCTMeasureOptions.default
options.iterationCount = 5
options.invocationOptions = [.manuallyStart, .manuallyStop]
measure(
  metrics: [XCTClockMetric(), XCTHitchMetric(application: app)],
  options: options
) {
  returnToKnownFirstPageThroughUI()
  startMeasuring()
  reader.swipeLeft(velocity: .slow)
  XCTAssertTrue(knownNextPassage.waitForExistence(timeout: 10))
  stopMeasuring()
  assertSavedLogicalAnchorThroughPublicHTTP()
}
```

Wait budgets are failure timeouts, not performance budgets. Keep screenshot capture, API readback, fixture resets and accessibility audits outside measured intervals. Keep the actual animation/destination settlement inside. For reduced motion, measure the usable alternative and assert its state; absent animation-signpost samples can be expected, but must not become a claimed smooth-animation pass. [Measure API](<https://developer.apple.com/documentation/xctest/xctestcase/measure(metrics:options:block:)>), [installed swipe API](/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/Library/Frameworks/XCUIAutomation.framework/Headers/XCUIElement.h:203).

Retain/export the result bundle and every metric sample, with config/fixture IDs and host load. The current harness already disables parallel native tests and exports screenshots/results. It does not export performance metrics or define reviewed performance budgets. Later execution can use the installed commands below after setting `BO_RESULT_BUNDLE` to the actual retained run's bundle:

```sh
xcrun xcresulttool export attachments --path "$BO_RESULT_BUNDLE" --output-path "$BO_METRIC_EVIDENCE/attachments"
xcrun xcresulttool get test-results metrics --path "$BO_RESULT_BUNDLE" > "$BO_METRIC_EVIDENCE/metrics.json"
xcrun xcresulttool export metrics --path "$BO_RESULT_BUNDLE" --output-path "$BO_METRIC_EVIDENCE/metrics-csv"
```

Source: installed `xcresulttool export attachments/metrics --help` and `get test-results metrics --help`; [existing result handling](../scripts/ipad/run-harness.mjs). Validate nonempty measured cases/iterations/expected identifiers, not only command exit status. Run visual and performance suites serially, preserve failures and avoid retries that hide variance. A reviewed budget record should bind each operation/metric/unit to device/runtime/build, fixture/network recipe, baseline sample set, absolute threshold/tolerance and reviewer. No numeric BookOrbit budget is established by this research. Apple offers hitch-rate interpretation guidance, but it is not an approved simulator or product-specific target. [Hitch interpretation](https://developer.apple.com/documentation/xcode/understanding-hitches-in-your-app).

Simulator metrics establish repeatable regressions on the pinned Mac environment. They cannot establish ProMotion cadence/physical input latency, Pencil Pro behavior, real audio/background interruptions, physical memory pressure, VoiceOver usability, installation/renewal or animation feel. Two simulated Pro sizes are layout evidence; required physical Pro measurements and human walkthrough remain separate. Genuine Settings motion/window setup, human-approved PNGs, reviewed performance thresholds and nonempty native metric samples are the concrete next gates.
