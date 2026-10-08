# Native audiobook player implementation

The production book details reader now opens audiobook files using the actual AVPlayer engine shared with the Reader Proof app. The shared engine retains the authenticated bounded resource loader, canonical manifest/playback-state models, opaque track identities and pinned account generation. Book details opened from Library, Dashboard, author or series browsing expose Read only when the signed-in account has LibraryDownload. The backend audiobook routes independently enforce that permission and book ownership.

## Controls and persistence

The production reader displays the real track-local engine clock and provides Play/Pause, a native seek slider, skip intervals, previous/next tracks and manifest-validated chapter selection. Tracks and chapters render lazily and remain bounded by the manifest's existing 4096-item limits. Unsupported native codecs produce an actual engine error and playback retry. Track selection saves and acknowledges the previous position before replacing the active asset; a failed or uncertain save keeps that asset open.

Pause, seek, track changes, background entry, explicit Save and Done capture the real engine position. Playback also saves every ten seconds. An uncertain PUT retains its exact operation ID, base revision, asset, local position and timestamp. Retry uses that same body; new navigation stays blocked until acknowledgment. The acknowledgment must match the requested track, manifest, exact next revision, expected server-clamped local milliseconds and timestamp. Conflicts and changed manifests block overwriting a newer state. Done waits for confirmation, or offers an explicit Close without saving action. Playback can still be paused while an automatic save is delayed; one later save captures that paused position after the original acknowledgment.

The player uses the spoken-audio session and declares the audio background mode. Actual MediaPlayer commands provide play, pause, toggle, skip and track-local seek, and Now Playing reports the current metadata, duration, elapsed time and rate. Interruption start and removal of an output route pause and save. An interruption resumes only when it interrupted playing audio and the system permits resumption. Track completion saves before advancing to the next asset. A cancellable monotonic sleep timer pauses and saves at its chosen deadline. Closing cancels preparations, resource requests and scheduled work, removes owned media targets and notifications, clears owned Now Playing metadata, and deactivates the audio session.

Speed, volume and skip intervals use generated AudioReaderSettings and defaults from packages/types. The settings screen saves all four owned audio fields to the existing PATCH reader/defaults/audio route when account reader synchronization is enabled. Otherwise it saves them under the API's account/server-scoped local namespace. Settings only apply after the corresponding acknowledgment; demo accounts cannot edit synchronized settings. The native request body matches PatchDefaultDto.set and the owning service's audio field validation. GET reader/defaults is decoded as its actual audio partial-settings map. These account defaults match the web audio settings scope.

## Evidence and remaining boundaries

Strict Swift 6 compilation of thirteen changed primary files with 104 actual production and proof source declarations passed in 4.345 seconds, with complete concurrency checking and warnings as errors. Exact initial command/result/log: /tmp/bookorbit-production-audio-primary-command.txt, /tmp/bookorbit-production-audio-primary-result.json and /tmp/bookorbit-production-audio-primary.log. Subsequent source adjustments require the final source checks below before acceptance.

The independent audio tester's original run63566 demonstrated genuine AAC and MP3 clock advancement, exact 3-second AAC seek with a 24-second total, second-track chapter navigation to 6000 ms and canonical server acknowledgment at revision1/62.5 percent. That run retained a Done Dynamic Type RED. Dedicated Medium candidate28b920a7 moved the genuine close action to a scalable safe-area row. The unchanged original native journey subsequently passed on run69083, including all three full audits, landscape, actual termination/relaunch at the acknowledged second-track six-second position and Done close. Browser acceptance remained pending when this implementation note was written. Earlier UI idle failures remain preserved; the single controlled cached simulator shutdown/boot allowed the journey to progress without establishing a source cause.

The production UI, automatic writes, delayed-write controls, account changes, media commands, interruptions, background playback, settings, sleep timer and queue advancement require a separate High tester at the public authenticated HTTP, actual native UI, actual browser and delivered-file boundaries. Reader Proof acceptance is narrower than production acceptance. No production runtime pass is claimed here.

Audio bookmarks, ebook/audio position bridging, recorded Read Along and separate TTS are separate remaining features. Broad native codec compatibility, long-file precision and memory/latency, seek/fault matrices, accessible visual configurations and acoustic/hardware behavior remain unproved. The existing loader has no representation validator for same-size file replacement, as explicitly recorded by the original feasibility note. Advancing the genuine playback clock does not establish captured audible output. There is no full issue-completion claim.

## Final source checks

- primary: exit 0, 3.716 seconds. Log: /tmp/bookorbit-production-audio-primary.log.
- types: exit 0, 1.29 seconds. Log: /tmp/bookorbit-production-audio-types.log.
- plugin-api: exit 0, 0.641 seconds. Log: /tmp/bookorbit-production-audio-plugin-api.log.
- server-types: exit 0, 22.136 seconds. Log: /tmp/bookorbit-production-audio-server-types.log.
- client-types: exit 0, 29.281 seconds. Log: /tmp/bookorbit-production-audio-client-types.log.
- server-eslint: exit 0, 143.924 seconds. Log: /tmp/bookorbit-production-audio-server-eslint.log.
- client-eslint: exit 0, 14.884 seconds. Log: /tmp/bookorbit-production-audio-client-eslint.log.
- xcodegen: exit 0, 0.086 seconds. Log: /tmp/bookorbit-production-audio-xcodegen.log.
- production-build: exit 0, 43.541 seconds. Log: /tmp/bookorbit-production-audio-production-build.log.
- proof-build: exit 0, 28.128 seconds. Log: /tmp/bookorbit-production-audio-proof-build.log.
- contracts: exit 0, 1.217 seconds. Log: /tmp/bookorbit-production-audio-contracts.log.
- diff: exit 0, 0.035 seconds. Log: /tmp/bookorbit-production-audio-diff.log.

Both native builds cover the installed simulator architectures. They retain the existing OIDC deprecated initializer and AppIntents metadata warnings; the targeted strict check of the changed declarations has no warnings. No warnings were hidden. Exact sequential commands and results are retained in /tmp/bookorbit-production-audio-source-check-config.json and /tmp/bookorbit-production-audio-source-checks.json. All source checks passed and the owned heavy lock was released. These checks establish compilation and static compatibility, while the independent production runtime handoff remains pending.
