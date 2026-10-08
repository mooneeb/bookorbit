# Comic image cache verification

The authenticated comic page route previously returned `Cache-Control: public, max-age=31536000, immutable`. Commit `7b78175f` changes that response to `private, no-store`, preserving the route, authorization checks, MIME type and streamed image bytes. The isolated QA checkout applied the same change as `9a4da8a2`.

The public HTTP reproduction uses a real migrated PostgreSQL fixture, BookOrbit server and delivered CBZ archive. Before the fix, `run-95241-179132-comic-http-cache-red` passed the artifact/access and progress journeys but failed the cache-policy journey on an actual `200 image/png` response with the public cache directive. Anonymous and restricted requests still returned 401 and 403 after authorized cache priming; this reproduction does not establish an authorization bypass.

After the fix, `run-1333-1791319378609` passed all three public HTTP journeys in 590.534 ms with zero failures, cancelled, skipped or todo tests. Its retained response is `200 image/png` with `Cache-Control: private, no-store`. The tests compare each streamed page with the exact bytes in the delivered archive, decode all three 600 by 800 images, verify natural filename order and reject unauthorized, malformed and out-of-range requests. The independent progress journey also passed.

The repair agent independently read both run logs, both cache-policy reports, the natural-order/hash reports and the passing before/after progress records, and opened all three actual delivered PNGs from each run. The page labels and complete panel borders are visible; the image hashes match between the failing and passing executions. Prettier, targeted controller ESLint and `git diff --check` passed before committing the source change.

Retained artifacts are under `/tmp/bookorbit-comic-qa-8f548c03/test-results/ipad/`, in each run's `comic-http/` directory: `run.log`, `cache-policy.json`, `natural-order.json`, `delivered.cbz`, `natural-page-1.png` through `natural-page-3.png`, and the progress JSON records. This verifies the cache defect autonomously without a physical iPad. It does not establish completion of the comic native fault batch or issue #2.
