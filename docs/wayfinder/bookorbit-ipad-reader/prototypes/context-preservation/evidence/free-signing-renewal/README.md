# Free signing renewal trial

Status: passed for the manual SideStore IPA renewal workflow on the intended iPad. Same-build renewal with USB disconnected and a controlled build 7 update both issued later profiles, preserved the original app identity and retained the saved data before launch. The user confirmed the original page, sentence, ink and local marker remained, and physical Pencil erase/Undo worked. This completes the physical work for the [signing prerequisite](https://github.com/mooneeb/bookorbit/issues/20).

The trial started with the [accepted preservation prototype](https://github.com/mooneeb/bookorbit/blob/1207bcc7d98d7418a1423e9204bf92a1ad691c49/docs/wayfinder/bookorbit-ipad-reader/prototypes/context-preservation/evidence/physical-review-build-5/README.md) installed as build 5 on the iPad Air 13-inch (M2), iPadOS 26.6.1. Its complete 175-file scratch area was copied to a private local backup before signing changes. The maintenance fixture initially retained editable ink revision 4, original page backgrounds and the local unsent marker. [Preparation evidence](preparation.json) records hashes and unsigned update builds 6 and 7.

The official iloader 2.3.10 archive matches the publisher's SHA256. Its extracted Mac app passes strict code-signature verification and Gatekeeper's notarized Developer ID assessment. The user completed its private sign-in. SideStore version `0.7.0-20260911.328+6032424a`, build `0700`, is now installed. Its bundle identifier has the expected SideStore family and the same Team suffix as the existing Xcode Personal Team. The full identifier is retained privately. LocalDevVPN 1.3.0, build 1, is installed, and the user confirms it is connected. AltStore 2.3 remains installed.

## Recorded attempts

Each JSON record captures its stage of the trial, including any checks still pending at that time. The consolidated summary and final physical review record the completed outcome.

- [First bootstrap attempt](bootstrap-attempt-1.json): SideStore downloaded, but signing returned HTTP 502 from the helper's public `client_info` endpoint. An independent probe reproduced the error, followed by HTTP 200. A fresh snapshot confirmed all 175 prototype scratch files retained their baseline hashes.
- [Successful bootstrap retry](bootstrap-retry.json): the user reported success, and device metadata verified the installed SideStore version and expected Team suffix. The preservation prototype was still installed as build 5 at this stage.
- [VPN setup](vpn-setup.json): verified the LocalDevVPN version and recorded the user's Connected confirmation. SideStore launched successfully.
- [First native sign-in](signin-attempt-1.json): the user reported `This action cannot be completed at this time (-80045)`, then confirmed successful sign-in after the requested configuration retry. The installed public server catalog contains SideStore (New), pointing to `new.ani.sidestore.io`; its public `client_info` endpoint returned HTTP 200 before that retry.
- [SideStore self-refresh](sidestore-self-refresh.json): the user confirmed refreshing SideStore and reopening it. Device metadata confirms its installed identity is unchanged. This is distinct from the reader's renewal trial.
- [Reader adoption preparation](adoption-preparation.json): the user enabled Customize AppID and Export Resigned IPAs. Unsigned builds 6 and 7 were copied into the reader's shared Documents area. A fresh backup verified all 175 scratch files were unchanged before the transition.
- [Reader build 6 adoption](build6-adoption.json): device metadata confirms build 6 under the original bundle identifier. All 175 scratch files retained identical hashes before launch, and the native launch succeeded. The reader-specific exported signed IPA contains a Personal Team profile issued 20 October 2026 at 19:16:40 UTC, expiring 27 October 2026 at 19:16:40 UTC. Its application identifier, Team and device match the intended installation. The actual signing certificate changed from the Xcode build's certificate while retaining the same Team; exact certificate fingerprints remain private.
- [Same-build iPad renewal](build6-ipad-renewal.json): the user disconnected USB, reimported the same build 6 IPA, then reconnected. The profile's issuance and expiration both advanced. All 175 pre-renewal files had identical hashes before launch, and the reader reopened successfully. AltServer was not running before the trial. The later launch added the active-walkthrough marker and incremented the record's reopen tracking; this produced the 176-file baseline for the next update.
- [Controlled build 7 update](build7-update.json): the original identifier and signing Team remained, the actual signer matches the adopted SideStore signer, all 176 pre-update files retained their hashes before launch, and the reader reopened successfully.
- [Final physical review](final-human-review.json): the user reported, "Everything was kept; erase and Undo work." The original context, PNG/PDF backgrounds and local marker remained unchanged. Editing advanced the ink revision from 4 to 6. The drawing file changed during the intentional erase/Undo check; the user's visible restoration result is the Undo acceptance evidence.

The [consolidated trial summary](trial-summary.json) records the resulting support boundary.

| Stage                                    | Reader build | Profile issued (UTC) | Profile expires (UTC) |
| ---------------------------------------- | ------------ | -------------------- | --------------------- |
| Existing Xcode install                   | 5            | 20 Oct 2026 14:11:25 | 27 Oct 2026 14:11:25  |
| SideStore adoption                       | 6            | 20 Oct 2026 19:16:40 | 27 Oct 2026 19:16:40  |
| Same-build renewal with USB disconnected | 6            | 20 Oct 2026 19:29:01 | 27 Oct 2026 19:29:01  |
| Controlled update                        | 7            | 20 Oct 2026 19:33:26 | 27 Oct 2026 19:33:26  |

The installed build 7 profile expires on 28 October 2026 at 00:33:26 in Asia/Karachi. Renew before the profile expires; the seven-day lifetime starts at issuance.

The sign-in retry follows a [contributor's suggestion in the upstream issue tracker](https://github.com/SideStore/SideStore/issues/1658#issuecomment-6232255981): disable on-device anisette, select SideStore (New), disable rotation, reset the login helper's provisioning state without retaining headers, then sign in again. The successful user report applies to this trial; it does not establish a general fix. The pinned app source confirms that these controls exist and preserve the active signing certificate when resetting login state. Account secrets, anisette provisioning data and Keychain contents have not been inspected.

## Reader identity and renewal path

The [source identity audit](identity-audit.json) found a limitation relevant to this existing Xcode prototype. The ordinary refresh pipeline defaults to appending a Team suffix and only reuses an installed identifier if it already contains that suffix. It does not run the AppID customization step. This is a source-based inference about the reader's ordinary refresh path, not an observed successful renewal.

The validated route uses full IPA imports on the iPad with Customize AppID enabled and Append Team ID unchecked. The trial proved initial adoption, renewal without a code update and a separate controlled update. The current unsigned build 7 IPA remains available in Files at On My iPad / Orbit Context PROTOTYPE / Signing Trial.

For this prototype's weekly renewal, connect Wi-Fi and LocalDevVPN, import the current unsigned IPA through SideStore's My Apps + button, retain `dev.mooneeb.bookorbit.contextprototype`, and uncheck Append Team ID. Keep the existing app installed. This is the tested manual renewal route; ordinary reader badge refresh and background renewal are not validated for this identifier. The final app's identity and renewal experience must respect this constraint before treating ordinary SideStore refresh as supported.

The tested signing transition is Xcode build 5 to SideStore build 6, followed by SideStore renewal and update. A reverse transition to Xcode was not needed or exercised in this successful route. The earlier Xcode bootstrap/update evidence remains separate; this trial does not claim a newly renewed Xcode profile or a reverse-transition result.

## Sources and identity checks

- [SideStore prerequisites](https://docs.sidestore.io/docs/installation/prerequisites) and [installation steps](https://docs.sidestore.io/docs/installation/install): initial computer setup, private Apple Account login, LocalDevVPN and an initial on-device refresh.
- [iloader 2.3.10](https://github.com/nab138/iloader/releases/tag/v2.3.10): official installer version used for preparation.
- [SideStore 0.7.0-alpha](https://github.com/SideStore/SideStore/releases/tag/0.7.0-alpha): the maintainers' current Latest release despite its tag name. Its notes identify older releases as having broken sign-in. The verified IPA reports version `0.7.0-20260911.328+6032424a`, build `0700`.
- [LocalDevVPN](https://apps.apple.com/us/app/localdevvpn/id6755608044): official App Store source. Both the listing and installed app reported version 1.3.0 during this trial.
- [iloader's pinned install path](https://github.com/nab138/iloader/blob/v2.3.10/src-tauri/src/sideload.rs) uses GitHub's latest release URL for its Stable SideStore button. Its pinned `isideload` 0.4.6 dependency appends the selected Team identifier to an ordinary IPA's bundle identifier. Use iloader for the SideStore bootstrap; inspect the prototype's actual identity before any transition. A separate app container does not establish preservation of the existing app's notes.
- [SideStore's pinned operation context](https://github.com/SideStore/SideStore/blob/6032424a0e56c1c319762e786099bdd9186a238b/SideStore/Core/Operations/OperationContexts.swift) and [resigning operation](https://github.com/SideStore/SideStore/blob/6032424a0e56c1c319762e786099bdd9186a238b/SideStore/Core/Operations/PipelineOperations/ResignAppOperation.swift) contain custom bundle identifier handling. The actual manual-import trials above verified the resulting installed identity.

The original eleven preservation behaviors are already accepted. This trial checks signing renewal and data retention only. The local marker is a scratch fixture; it does not exercise production server sync.

No production client/server behavior or running BookOrbit deployment changed. Raw signed IPAs, provisioning profiles, certificate fingerprints, account identifiers and complete local backups remain private and are excluded from this evidence directory.
