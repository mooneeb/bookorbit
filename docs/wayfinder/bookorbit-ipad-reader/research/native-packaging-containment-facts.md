# Native packaging and web containment facts

Checked **2026-10-23**, as a bounded supplement to [Reader stack: current facts](reader-stack-current-facts.md) and [Native platform and reader stack facts](native-platform-stack-facts.md), for [Choose the native app boundary and reader stack](https://github.com/mooneeb/bookorbit/issues/10). Repository baseline: `ebf17719a2207eb9dd0abad32830b12d9c63992b`, branch `BO-10-native-reader-stack`. **Documented** identifies primary-source facts; **observed** identifies retained fixture evidence; **inference** identifies integration consequences. This note selects no stack, packaging policy or authentication protocol.

Scope remains the accepted online book management with native library, reader controls, notes, downloads and sync UI; advanced management reuses existing pages inside the app. Unprotected EPUB/PDF reading, VoiceOver book text/notes and larger UI text remain requirements; administration and Kobo stay on the website. [Accepted management/accessibility discussion](https://github.com/mooneeb/bookorbit/issues/10#issuecomment-6370068019). The supplied runtime is iPadOS **26.6.1**; Xcode **27 / Swift 6.4** is toolchain context, not evidence that 27-only runtime APIs are available.

## Free signing, capabilities and separate app identity

**Documented:** Apple's free Personal Team supports up to **10 registered App IDs**, **3 registered devices** and **3 installed apps per device**. Apple states that those App IDs/devices expire after seven days and installation profiles expire seven days after issuance. SideStore separately confirms **three installed apps including SideStore itself**, and ten App IDs in a week. These are distinct limits: ten App IDs do not permit ten simultaneous installed apps. [Apple account limits][apple-account], [official SideStore FAQ][sidestore-faq].

Apple's current capability table leaves the free Apple Developer column empty for **push notifications**, all three listed **iCloud** services, **associated domains** and **Sign in with Apple**. It marks **App groups**, **Background modes**, **Data protection** and **Keychain sharing** as available in that column. App Groups must therefore not be described categorically as paid-only. This is a capability matrix, not a guarantee of any final signed entitlement set or background execution. [Apple capability table and membership definitions][apple-capabilities].

**Inference:** a single-app reader using the proposed system UI/reading frameworks, local storage, app-owned credentials and URLSession does not acquire a paid-capability requirement merely by using those APIs. Under the stated absence of extensions, push, iCloud and App Groups, no required paid capability was identified. A final target's actual capabilities/provisioning still need inspection when it exists; this research neither builds nor signs that app. Personal-device development and App Store/TestFlight distribution remain different authorizations. [Apple account scope][apple-account], [capability matrix][apple-capabilities].

Apple registers an App ID from a target's bundle identifier. The existing prototype uses `dev.mooneeb.bookorbit.contextprototype`. **Conditional arithmetic for the proposed separate production bundle ID:** SideStore + retained prototype + reader = **3 counted apps**, leaving zero spare slots under the ordinary free limit. Any other counted free-signed app adds to that total; retaining a counted AltStore as well would make **4**. The historical renewal record mentions AltStore, but establishes neither today's inventory nor today's available slots/App IDs. A separate extension-free reader adds one app identity; do not infer SideStore's total App ID consumption from its one installed-app slot. No limit bypass or production installation is established here. [Apple bundle identity][apple-bundle], [prototype target][prototype-target], [retained signing evidence][renewal], [SideStore limits][sidestore-faq].

**Observed and already completed:** [Validate free signing renewal and note preservation on the intended iPad](https://github.com/mooneeb/bookorbit/issues/20) passed manual same-AppID SideStore renewal and controlled update, retaining data and editable originals. Its tested route imports the unsigned IPA with Customize AppID and Append Team ID unchecked. Ordinary badge/background renewal for that prototype identity was not validated. A separate production bundle ID does not reopen that completed trial, prove installation capacity, transfer the prototype's data, or prove the new identity's renewal behavior. [Completed trial and exact support boundary][renewal].

## Online management sessions and the local EPUB boundary

### Persistent stores are available on the supplied runtime

**Documented:** `WKWebsiteDataStore(forIdentifier:)` supports multiple persistent stores from **iPadOS 17**. Reusing its UUID retrieves the store, creating it if absent; the app must remember the identifier across relaunch. Separate stores separate cookies and other website data. Assign the store to `WKWebViewConfiguration` **before creating** the web view. The default store is persistent; `nonPersistent()` creates an in-memory store. Removing an identified store can fail while a web view still uses it. These APIs are available on 26.6.1 without requiring a 27 runtime. [WebKit profiles guide][wk-profiles], [initializer availability][wk-store-init], [configuration/default behavior][wk-store], [nonpersistent store][wk-nonpersistent].

**Inference:** server/account isolation can map each management session scope to its own stable store UUID. A random UUID at every launch loses the existing profile association; the default store alone does not separate multiple accounts. Store identity does not replace server authorization or scope native files/database records. The untrusted local EPUB view needs a **different store and content controller**, with no management cookies or credential bridge. A separate content world alone is insufficient because worlds share the DOM. This states the containment boundary, without choosing persistent versus ephemeral book-store lifetime. [Profile isolation][wk-profiles], [content-world scope][wk-world].

`WKHTTPCookieStore`, available from iPadOS 11, is obtained from the selected website data store. It can read, set, delete and observe cookies; `setCookie` completes asynchronously after storage. It is a cookie-storage primitive, not a server login exchange or a Keychain interface. Any intentional cookie setup must target the intended store and await completion before dependent loading. [Cookie store][wk-cookies], [set-cookie completion][wk-set-cookie].

### Current server/web authentication is not a native-to-web handoff

**Source evidence at the baseline:**

- `POST /api/v1/auth/login` and `POST /api/v1/auth/oidc/callback` use DTOs inheriting optional validated `clientKind: 'web' | 'native'` and `deviceLabel`. Native login returns `accessToken`, `accessTokenExpiresAt`, `refreshToken`, `refreshTokenExpiresAt`, `sessionId` and `user`, without setting authentication cookies. `POST /api/v1/auth/refresh` accepts the refresh credential in the JSON body. [Auth routes][auth-controller], [client DTO][auth-client], [login DTO][auth-login], [OIDC DTO][auth-oidc-dto], [shared response fields][auth-types], [credential delivery][auth-delivery].
- Web login instead sets HttpOnly `refresh_token` (`SameSite=Strict`, path `/api/v1/auth`) and `access_token` (`SameSite=Lax`, path `/api`), both `secure: 'auto'`. Web JSON excludes the refresh credential. The web client keeps the returned access token in memory, sends Bearer authorization plus cookies, and restores its session with cookie-based refresh. The JWT strategy accepts Bearer first, then the access cookie. [Cookie attributes][auth-cookies], [web login/initialization][web-auth], [web requests/refresh][web-api], [JWT extraction][auth-jwt].
- Refresh rejects a body/cookie credential conflict and requires the stored session's `clientKind` to match the selected transport: body refresh is native, cookie-only refresh is web. **Inference:** putting a native refresh credential into a web cookie does not convert its session and fails this refresh check. A copied access credential would not establish the complete web refresh lifecycle. [Refresh implementation][auth-refresh], [existing transport test source][auth-transport-tests].

**Bounded negative finding:** the inspected auth controller, DTOs, session transport and web bootstrap contain no dedicated one-time native-session-to-web-session handoff. The OIDC callback exchanges an identity-provider authorization code; it is not that missing handoff. Existing magic-link login checks an active token and updates usage, rather than consuming a one-time native handoff. Those routes must not be relabeled as an already implemented single-sign-on bridge. This is baseline source inspection, not a claim about private/native app code or a deployed server. [Auth routes][auth-controller], [OIDC login issuance][auth-oidc], [magic-link login][auth-magic].

### Origin checks and typed messages remain host work

**Documented:** WebKit delivers `WKScriptMessage.body` as `Any`; registering a handler in a content world exposes it in **all frames** in that world. A message supplies its world and sending `frameInfo`; frame security origin supplies protocol, host and port. Content worlds separate JavaScript variables, not the shared DOM. A reply-capable handler adds a reply mechanism, not authentication or schema validation. [Message body][wk-body], [handler registration][wk-add-handler], [message frame][wk-message-frame], [message world][wk-message-world], [security origin][wk-origin], [reply handler][wk-reply].

**Inference for contained management pages:** any native bridge needs a bounded, versioned command/payload schema, permitted operations, current server/account context and validation of the sending web view, world, frame and exact origin tuple. A page-supplied `origin` string or the web view's top-level URL alone cannot identify the sender. Management and EPUB need different permitted message sets; legitimate EPUB spine frames need an explicit frame/source rule. No bridge operation should return native credentials, Keychain contents or account secrets, or provide arbitrary native URL/file execution. The management website necessarily retains its existing web-auth flow; that does not authorize injecting native credentials into it.

Navigation delegates can allow/cancel requests; new-window navigation has `targetFrame == nil` and a separate UI-delegate creation path. A containment implementation must apply its configured origin/route rules across navigation, redirects and new windows, rather than only checking the initial URL or matching a hostname suffix. App-bound domains allow up to ten declared domains, treat local content as app-bound, and constrain the **top-level** frame while permitting third-party subframes. They are not a substitute for message-origin checks or a general subresource firewall. This note chooses no origin list, authentication redirect exceptions or app-bound-domain policy. [Navigation decisions][wk-navigation], [new-window target][wk-target-frame], [new-view callback][wk-new-window], [WebKit app-bound domain rules][wk-app-bound].

## Exact Foliate assets, licenses and remaining provenance

**Observed source inventory:** the baseline Foliate tree `699972b4e38f1a5fe76bb16f308952e0ec3463c5` has **21 files / 335,802 bytes**: 18 JavaScript files and three declarations. It includes both `vendor/zip.js` and `vendor/fflate.js`, with no LICENSE, NOTICE, package manifest, source map, SPDX identifier, copyright notice or component-version header anywhere in that directory. This is an absence in the shipped snapshot, not evidence that the upstream components lack licenses. [Exact baseline tree][foliate-tree].

**New attribution evidence:** BookOrbit's original import at `cb3936444052f8501a377240e0d1f9ee4130b66e` contains ZIP and fflate bundles **byte-for-byte identical** to Foliate revision `ae61c5e85fb31ff4f46cd6bc74ebc6ac5971cca8`. Their only later local change was in `244d38afe8b3f45846458e24734fd5ff2ee49815`; formatting the import and baseline in memory with installed Prettier 3.9.9 and repository configuration produces identical output for each pair. The baseline files themselves are not byte-identical to upstream. [BookOrbit import][foliate-import], [later transformation][foliate-format], [matching upstream ZIP][upstream-zip], [matching upstream fflate][upstream-fflate].

SHA-256 identities, in `zip.js`, `fflate.js` order:

```text
baseline zip.js, 94,510 bytes:
ffdb8b9aed125627f90bc317b477db29f9a6556ae318ab727db4dfaacf888618
import/upstream zip.js, 55,329 bytes:
983ce42f4461c9d718c7f84cdce43dedb8215e1dbb3ce0f60008e315f5351269
baseline fflate.js, 6,785 bytes:
88fd758955f0e1445300f3777c7ebfe4f770c462221670df98025a60335c41e0
import/upstream fflate.js, 3,830 bytes:
130855b45faa6e69c12b21180de843a3c1d714e1597d37ed92cec8d1af53b85d
```

The matching Foliate revision locks **`@zip.js/zip.js 2.7.52`** and **`fflate 0.8.2`**. Its Rollup entry points select `zip-no-worker-inflate.js` exports and `fflate.unzlibSync`, matching the shipped API surfaces. Both primary npm tarballs were inspected in memory and matched the lockfile's SHA-512 integrity. The reduced bundles were not whole-file matches to package JS artifacts, and the Rollup build was not reproduced. This establishes attributable archive-component origins, not a unique base for the whole Foliate library. [ZIP lock entry][upstream-lock], [fflate lock entry][fflate-lock], [ZIP entry point][zip-entry], [fflate entry point][fflate-entry], [build configuration][upstream-rollup], [ZIP package artifact][zip-package], [fflate package artifact][fflate-package].

The relevant primary notices distinguish:

- **Foliate:** MIT, copyright **2022 John Factotum**. [Pinned license][foliate-license].
- **zip.js 2.7.52:** BSD-3-Clause, copyright **2023 Gildas Lormeau**. Its included inflate source separately carries a **2022 Gildas Lormeau** notice with a JCraft disclaimer and credits **JZlib 1.0.2 / ymnk / JCraft**, **zlib 1.1.3**, **Jean-loup Gailly** and **Mark Adler**. The package license alone loses those codec notices. [Package license][zip-license], [inflate notice/credits][zip-inflate].
- **fflate 0.8.2:** MIT, copyright **2023 Arjun Barrett**; source also acknowledges similarity to UZIP.js. [License][fflate-license], [source acknowledgment][fflate-source].

The web loader imports ZIP for archive opening and fflate for MOBI. EPUB/PDF-only product scope does not prove fflate is absent from a package that copies this entire directory. The prototype resource target currently copies the directory wholesale. [ZIP import][foliate-loader], [MOBI import][foliate-mobi], [resource target][prototype-target].

**Remaining before native bundling:** record exact included files/hashes, component pins, matching upstream artifacts and local transformations; recover a library-wide Foliate base or document per-file origins; include the full applicable MIT/BSD copyright, permission/condition/disclaimer texts and codec acknowledgments in distributed materials. Preserve provenance for BookOrbit additions/modifications under its recorded AGPL-3.0-only license and additional terms. The matching archive revision is not a proven base for all 21 files. This is a notice/provenance work list, **not a blanket distribution-compatibility or legal conclusion**. [Foliate notice requirement][foliate-license], [zip.js redistribution conditions][zip-license], [fflate notice requirement][fflate-license], [BookOrbit license declaration][bookorbit-license], [additional terms][bookorbit-terms].

Method/limits: primary Apple/WebKit documentation, raw capability-table HTML and API availability metadata; baseline code and retained evidence; a bounded read-only background provenance task plus direct artifact/hash cross-checks. No code edits, Git commits/index/ref changes, GitHub mutations, server/device/signing/account changes or installations; no secrets or Keychain contents inspected. No runtime tests, signing trial, build or production authentication/containment test ran. The existing successful manual renewals remain accepted. Only this research file was written by this follow-up.

[apple-account]: https://developer.apple.com/help/account/basics/about-your-developer-account
[sidestore-faq]: https://docs.sidestore.io/docs/faq
[apple-capabilities]: https://developer.apple.com/help/account/reference/supported-capabilities-ios
[apple-bundle]: https://developer.apple.com/documentation/xcode/changing-the-bundle-identifier
[prototype-target]: https://github.com/mooneeb/bookorbit/blob/ebf17719a2207eb9dd0abad32830b12d9c63992b/docs/wayfinder/bookorbit-ipad-reader/prototypes/context-preservation/project.yml
[renewal]: https://github.com/mooneeb/bookorbit/blob/ebf17719a2207eb9dd0abad32830b12d9c63992b/docs/wayfinder/bookorbit-ipad-reader/prototypes/context-preservation/evidence/free-signing-renewal/README.md
[wk-profiles]: https://webkit.org/blog/14423/building-profiles-with-new-webkit-api/
[wk-store-init]: https://developer.apple.com/tutorials/data/documentation/webkit/wkwebsitedatastore/init(foridentifier:).json
[wk-store]: https://developer.apple.com/documentation/webkit/wkwebsitedatastore
[wk-nonpersistent]: https://developer.apple.com/documentation/webkit/wkwebsitedatastore/nonpersistent()
[wk-world]: https://developer.apple.com/documentation/webkit/wkcontentworld
[wk-cookies]: https://developer.apple.com/documentation/webkit/wkhttpcookiestore
[wk-set-cookie]: https://developer.apple.com/documentation/webkit/wkhttpcookiestore/setcookie(_:completionhandler:)
[auth-client]: https://github.com/mooneeb/bookorbit/blob/ebf17719a2207eb9dd0abad32830b12d9c63992b/server/src/modules/auth/dto/auth-client.dto.ts
[auth-login]: https://github.com/mooneeb/bookorbit/blob/ebf17719a2207eb9dd0abad32830b12d9c63992b/server/src/modules/auth/dto/login.dto.ts
[auth-oidc-dto]: https://github.com/mooneeb/bookorbit/blob/ebf17719a2207eb9dd0abad32830b12d9c63992b/server/src/modules/auth/dto/oidc-callback.dto.ts
[auth-types]: https://github.com/mooneeb/bookorbit/blob/ebf17719a2207eb9dd0abad32830b12d9c63992b/packages/types/src/auth.ts#L164-L193
[auth-delivery]: https://github.com/mooneeb/bookorbit/blob/ebf17719a2207eb9dd0abad32830b12d9c63992b/server/src/modules/auth/auth.service.ts#L411-L418
[auth-cookies]: https://github.com/mooneeb/bookorbit/blob/ebf17719a2207eb9dd0abad32830b12d9c63992b/server/src/modules/auth/auth.service.ts#L663-L704
[web-auth]: https://github.com/mooneeb/bookorbit/blob/ebf17719a2207eb9dd0abad32830b12d9c63992b/client/src/features/auth/composables/useAuth.ts#L125-L159
[web-api]: https://github.com/mooneeb/bookorbit/blob/ebf17719a2207eb9dd0abad32830b12d9c63992b/client/src/lib/api.ts
[auth-jwt]: https://github.com/mooneeb/bookorbit/blob/ebf17719a2207eb9dd0abad32830b12d9c63992b/server/src/modules/auth/jwt.strategy.ts#L15-L19
[auth-refresh]: https://github.com/mooneeb/bookorbit/blob/ebf17719a2207eb9dd0abad32830b12d9c63992b/server/src/modules/auth/auth.service.ts#L352-L379
[auth-transport-tests]: https://github.com/mooneeb/bookorbit/blob/ebf17719a2207eb9dd0abad32830b12d9c63992b/server/src/modules/auth/auth-session-transport.test.ts#L56-L94
[auth-controller]: https://github.com/mooneeb/bookorbit/blob/ebf17719a2207eb9dd0abad32830b12d9c63992b/server/src/modules/auth/auth.controller.ts
[auth-oidc]: https://github.com/mooneeb/bookorbit/blob/ebf17719a2207eb9dd0abad32830b12d9c63992b/server/src/modules/auth/oidc/oidc.service.ts#L241-L263
[auth-magic]: https://github.com/mooneeb/bookorbit/blob/ebf17719a2207eb9dd0abad32830b12d9c63992b/server/src/modules/auth/magic-link.service.ts#L79-L118
[wk-body]: https://developer.apple.com/documentation/webkit/wkscriptmessage/body
[wk-add-handler]: https://developer.apple.com/documentation/webkit/wkusercontentcontroller/add(_:contentworld:name:)
[wk-message-frame]: https://developer.apple.com/documentation/webkit/wkscriptmessage/frameinfo
[wk-message-world]: https://developer.apple.com/documentation/webkit/wkscriptmessage/world
[wk-origin]: https://developer.apple.com/documentation/webkit/wksecurityorigin
[wk-reply]: https://developer.apple.com/documentation/webkit/wkscriptmessagehandlerwithreply
[wk-navigation]: https://developer.apple.com/documentation/webkit/wknavigationdelegate/webview(_:decidepolicyfor:decisionhandler:)-2ni62
[wk-target-frame]: https://developer.apple.com/documentation/webkit/wknavigationaction/targetframe
[wk-new-window]: https://developer.apple.com/documentation/webkit/wkuidelegate/webview(_:createwebviewwith:for:windowfeatures:)
[wk-app-bound]: https://webkit.org/blog/10882/app-bound-domains/
[foliate-tree]: https://github.com/mooneeb/bookorbit/tree/ebf17719a2207eb9dd0abad32830b12d9c63992b/client/public/assets/foliate
[foliate-import]: https://github.com/mooneeb/bookorbit/commit/cb3936444052f8501a377240e0d1f9ee4130b66e
[foliate-format]: https://github.com/mooneeb/bookorbit/commit/244d38afe8b3f45846458e24734fd5ff2ee49815
[upstream-zip]: https://github.com/johnfactotum/foliate-js/blob/ae61c5e85fb31ff4f46cd6bc74ebc6ac5971cca8/vendor/zip.js
[upstream-fflate]: https://github.com/johnfactotum/foliate-js/blob/ae61c5e85fb31ff4f46cd6bc74ebc6ac5971cca8/vendor/fflate.js
[upstream-lock]: https://github.com/johnfactotum/foliate-js/blob/ae61c5e85fb31ff4f46cd6bc74ebc6ac5971cca8/package-lock.json#L428-L439
[fflate-lock]: https://github.com/johnfactotum/foliate-js/blob/ae61c5e85fb31ff4f46cd6bc74ebc6ac5971cca8/package-lock.json#L676-L682
[zip-entry]: https://github.com/johnfactotum/foliate-js/blob/ae61c5e85fb31ff4f46cd6bc74ebc6ac5971cca8/rollup/zip.js
[fflate-entry]: https://github.com/johnfactotum/foliate-js/blob/ae61c5e85fb31ff4f46cd6bc74ebc6ac5971cca8/rollup/fflate.js
[upstream-rollup]: https://github.com/johnfactotum/foliate-js/blob/ae61c5e85fb31ff4f46cd6bc74ebc6ac5971cca8/rollup.config.js#L17-L32
[zip-package]: https://registry.npmjs.org/@zip.js/zip.js/-/zip.js-2.7.52.tgz
[fflate-package]: https://registry.npmjs.org/fflate/-/fflate-0.8.2.tgz
[foliate-license]: https://github.com/johnfactotum/foliate-js/blob/ae61c5e85fb31ff4f46cd6bc74ebc6ac5971cca8/LICENSE
[zip-license]: https://github.com/gildas-lormeau/zip.js/blob/v2.7.52/LICENSE
[zip-inflate]: https://github.com/gildas-lormeau/zip.js/blob/v2.7.52/lib/core/streams/codecs/inflate.js#L1-L34
[fflate-license]: https://github.com/101arrowz/fflate/blob/v0.8.2/LICENSE
[fflate-source]: https://github.com/101arrowz/fflate/blob/v0.8.2/src/index.ts#L1-L8
[foliate-loader]: https://github.com/mooneeb/bookorbit/blob/ebf17719a2207eb9dd0abad32830b12d9c63992b/client/public/assets/foliate/view.js#L86-L99
[foliate-mobi]: https://github.com/mooneeb/bookorbit/blob/ebf17719a2207eb9dd0abad32830b12d9c63992b/client/public/assets/foliate/view.js#L182-L185
[bookorbit-license]: https://github.com/mooneeb/bookorbit/blob/ebf17719a2207eb9dd0abad32830b12d9c63992b/client/package.json
[bookorbit-terms]: https://github.com/mooneeb/bookorbit/blob/ebf17719a2207eb9dd0abad32830b12d9c63992b/ADDITIONAL_TERMS.md
