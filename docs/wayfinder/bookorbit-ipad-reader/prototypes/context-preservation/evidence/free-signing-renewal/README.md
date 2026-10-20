# Free signing renewal trial

Status: prepared, awaiting private native login. The [signing prerequisite](https://github.com/mooneeb/bookorbit/issues/20) remains open. No renewal or SideStore compatibility result has been established.

The [accepted preservation prototype](https://github.com/mooneeb/bookorbit/blob/1207bcc7d98d7418a1423e9204bf92a1ad691c49/docs/wayfinder/bookorbit-ipad-reader/prototypes/context-preservation/evidence/physical-review-build-5/README.md) remains installed as build 5 on the iPad Air 13-inch (M2), iPadOS 26.6.1. Its complete 175-file scratch area was copied to a private local backup before signing changes. The maintenance fixture retains editable ink revision 4, original page backgrounds and the local unsent marker. [Preparation evidence](preparation.json) records hashes and unsigned update builds 6 and 7.

The official iloader 2.3.10 archive matches the publisher's SHA256. Its extracted Mac app passes strict code-signature verification and Gatekeeper's notarized Developer ID assessment, and is open for the user to sign in. The official SideStore IPA is downloaded and verified but has not been installed. AltStore 2.3 already exists on the iPad and remains intact; LocalDevVPN is absent at this stage.

## Sources and identity checks

- [SideStore prerequisites](https://docs.sidestore.io/docs/installation/prerequisites) and [installation steps](https://docs.sidestore.io/docs/installation/install): initial computer setup, private Apple Account login, LocalDevVPN and an initial on-device refresh.
- [iloader 2.3.10](https://github.com/nab138/iloader/releases/tag/v2.3.10): official installer version used for preparation.
- [SideStore 0.7.0-alpha](https://github.com/SideStore/SideStore/releases/tag/0.7.0-alpha): the maintainers' current Latest release despite its tag name. Its notes identify older releases as having broken sign-in. The verified IPA reports version `0.7.0-20260911.328+6032424a`, build `0700`.
- [LocalDevVPN](https://apps.apple.com/us/app/localdevvpn/id6755608044): official App Store source. The listing reports 1.3.0; the installed version must be checked after installation.
- [iloader's pinned install path](https://github.com/nab138/iloader/blob/v2.3.10/src-tauri/src/sideload.rs) uses GitHub's latest release URL for its Stable SideStore button. Its pinned `isideload` 0.4.6 dependency appends the selected Team identifier to an ordinary IPA's bundle identifier. Use iloader for the SideStore bootstrap; inspect the prototype's actual identity before any transition. A separate app container does not establish preservation of the existing app's notes.
- [SideStore's pinned operation context](https://github.com/SideStore/SideStore/blob/6032424a0e56c1c319762e786099bdd9186a238b/SideStore/Core/Operations/OperationContexts.swift) and [resigning operation](https://github.com/SideStore/SideStore/blob/6032424a0e56c1c319762e786099bdd9186a238b/SideStore/Core/Operations/PipelineOperations/ResignAppOperation.swift) contain custom bundle identifier handling. Its UI and resulting installed identity still require an actual trial.

## Remaining physical trial

1. Complete login and iPad selection in iloader using the same Apple Account as the existing Xcode Personal Team. Inspect any certificate revocation prompt before proceeding because AltStore already exists.
2. Install the official SideStore and LocalDevVPN, complete device trust prompts, and perform SideStore's first on-device refresh.
3. Establish a route that preserves the prototype's installed identity, then verify a genuinely new provisioning profile, successful reopening and unchanged retained fixture data. Record actual profile issuance and expiration privately, publishing sanitized dates only.
4. Install the controlled update, compare the fixture before launch, then have the user verify the original page, erase and Undo after renewal.
5. If SideStore concretely fails, retain the fixture and test the authorized free Xcode fallback with a newly issued profile. Document the observed scope of support.

The original eleven preservation behaviors are already accepted. This trial checks signing renewal and data retention only. The local marker is a scratch fixture; it does not exercise production server sync.
