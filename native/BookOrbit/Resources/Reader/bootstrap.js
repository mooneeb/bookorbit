const session = location.pathname.split("/")[1];
const fail = () =>
  window.webkit.messageHandlers.reader.postMessage({
    session,
    kind: "error",
    value: "Trusted reader assets could not load. Return to details and retry.",
  });
window.addEventListener("error", fail);
window.addEventListener("unhandledrejection", fail);
import("./reader.js").then(() => {
  window.removeEventListener("error", fail);
  window.removeEventListener("unhandledrejection", fail);
}, fail);
