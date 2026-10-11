import assert from "node:assert/strict";
import { readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { compareAnnotationVisual } from "./annotation-visual.mjs";

export async function compareReadingSharingVisual(options) {
  return compareAnnotationVisual({ ...options, ticket: "E04" });
}

export async function compareNativeReadingSharingVisuals(artifacts, profile) {
  const entries = JSON.parse(await readFile(join(artifacts, "native-attachments/manifest.json"), "utf8"));
  const privacyScreenshots = {
    "ReadingPrivacyJourneyTests/testIPADE04A02PrivateSaveVisibleOutcome()": ["P-N01-private-save-visible-outcome"],
    "ReadingPrivacyJourneyTests/testIPADE04A02PrivateSaveCanonicalState()": ["P-N01-private-canonical-after-native-save-and-reopen"],
    "ReadingPrivacyJourneyTests/testIPADE04A02PrivateSaveVisibleFailureRecovery()": [
      "P-N01-private-save-visible-failure-preserves-selection",
      "P-N01-private-save-recovered-with-one-native-retry",
    ],
    "ReadingPrivacyJourneyTests/testIPADE04A02RetainedPrivacyToolbarAccessibilityAndDismissal()": [
      `P-N01-retained-privacy-toolbar-${profile}`,
      `P-N01-retained-privacy-dismissed-${profile}`,
    ],
  };
  const reports = [];
  for (const entry of entries) {
    for (const attachment of entry.attachments) {
      const name = attachment.suggestedHumanReadableName?.replace(/_\d+_[A-Fa-f0-9-]+\.png$/, "");
      const match = name?.match(/^IPAD-E04-(?:A0([1-5])|QA([1-5]))-(.+)$/);
      const feedback = name?.match(/^EMAIL-M03-(.+)$/);
      const privacy = privacyScreenshots[entry.testIdentifier]?.includes(name);
      if ((!match && !feedback && !privacy) || !attachment.exportedFileName.endsWith(".png")) continue;
      reports.push(
        await compareReadingSharingVisual({
          actualPath: join(artifacts, "native-attachments", attachment.exportedFileName),
          outputDir: join(artifacts, "native-visual"),
          testId: match ? `IPAD-E04-A0${match[1] ?? match[2]}` : privacy ? "IPAD-E04-A02" : "IPAD-E04-A03",
          state: match ? match[3] : privacy ? name.slice("P-N01-".length) : `email-feedback-${feedback[1]}`,
          surface: "native",
          profile,
          metadata: {
            testIdentifier: entry.testIdentifier,
            deviceName: attachment.deviceName,
            deviceId: attachment.deviceId,
            configurationName: attachment.configurationName,
            attachmentName: name,
          },
        }),
      );
    }
  }
  await writeFile(join(artifacts, "native-visual-report.json"), `${JSON.stringify(reports, null, 2)}\n`);
  assert.ok(reports.length > 0, "Native E04 journeys must capture named screenshots");
  assert.ok(
    reports.every((report) => !report.status.startsWith("failed")),
    "Native E04 visual regression failed; inspect expected/actual/diff artifacts",
  );
  return reports;
}
