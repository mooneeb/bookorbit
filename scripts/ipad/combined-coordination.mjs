import { setTimeout } from "node:timers/promises";

export async function waitForNativeOfflineReady({ faultURL, deadline, signal }) {
  if (!Number.isSafeInteger(deadline)) throw new Error("Native readiness requires the owning run deadline");
  while (true) {
    signal.throwIfAborted();
    const remaining = deadline - Date.now();
    if (remaining <= 0) throw new Error("Native readiness exceeded the owning run deadline");
    const response = await fetch(`${faultURL}/__faults/annotations/checkpoint/native-offline-ready`, {
      signal: AbortSignal.any([signal, AbortSignal.timeout(Math.min(5_000, remaining))]),
    });
    if (!response.ok) throw new Error(`Native readiness checkpoint returned ${response.status}`);
    const value = await response.json();
    if (value.reached === true) {
      signal.throwIfAborted();
      if (Date.now() >= deadline) throw new Error("Native readiness exceeded the owning run deadline");
      return;
    }
    const delay = Math.min(250, deadline - Date.now());
    if (delay <= 0) throw new Error("Native readiness exceeded the owning run deadline");
    await setTimeout(delay, undefined, { signal });
  }
}
