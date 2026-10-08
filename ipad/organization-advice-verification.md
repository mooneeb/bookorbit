# Restricted organization advice wrapping

Issue #2's actual native organization run `run-30295-1791320921117` reported
Dynamic Type clipping for the empty-directory advice in both Authors and Series.
The complete audit attachments are
`4F40F9BF-DBA4-42C6-965E-BA8C99EA7FA5.txt` and
`128E8D27-9F2F-461B-93BA-62DB6CE93EDB.txt`. Each identifies the same advisory
static text with a `523.5 x 42.5` point frame.

Both full native images, `A7268A32-8742-417B-944A-D33F3D5E176C.png` and
`B74D8CBC-CFC2-4CF1-B3B5-068259027242.png`, and the cropped advice image
`F768238E-25FA-46C2-B4EF-4A7ECD769BF6.png` were opened and inspected. They are
retained under the organization tester's run directory at
`/tmp/bookorbit-organization-qa-98cc85a0/test-results/ipad/run-30295-1791320921117/native-attachments/`.

The correction lets the advisory text retain its full wrapped vertical size
while respecting the available horizontal width. Its wording, body text style,
semantic label color, accessibility text, and empty-result condition remain
unchanged. No test or accessibility audit is suppressed or narrowed.

Strict Swift formatting, parser validation, and a clean diff check pass for the
source change. Full compilation and the unfiltered native accessibility audits
remain pending the tester's next run. This source correction does not establish
a passing Dynamic Type check until the new runtime result and actual images
have been inspected.
