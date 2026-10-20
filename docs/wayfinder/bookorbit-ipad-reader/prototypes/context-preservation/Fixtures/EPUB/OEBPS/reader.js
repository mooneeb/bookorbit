async function prepareFixture(mode) {
  return Promise.race([
    prepareResources(mode),
    new Promise((_, reject) => setTimeout(() => reject(new Error("Required resource readiness exceeded 8 seconds")), 8000)),
  ]);
}

async function prepareResources(mode) {
  document.documentElement.className = mode === "columns" ? "columns" : "";
  await document.fonts.load("20px FixtureSerif");
  await document.fonts.ready;
  await Promise.all(Array.from(document.images, (image) => image.decode()));
  if (!document.fonts.check("20px FixtureSerif")) throw new Error("Required font unavailable");
  const target = document.getElementById("target");
  const rect = target.getBoundingClientRect();
  const x = mode === "columns" ? Math.max(0, rect.left + window.scrollX - 40) : 0;
  const y = mode === "columns" ? 0 : Math.max(0, rect.top + window.scrollY - 80);
  const deadline = performance.now() + 3000;
  do {
    window.scrollTo(x, y);
    await new Promise((resolve) => setTimeout(resolve, 50));
  } while ((Math.abs(window.scrollX - x) > 1 || Math.abs(window.scrollY - y) > 1) && performance.now() < deadline);
  await new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)));
  const word = document.getElementById("useful").getBoundingClientRect();
  return {
    scrollX: window.scrollX,
    scrollY: window.scrollY,
    viewportWidth: innerWidth,
    viewportHeight: innerHeight,
    font: "Source Serif 4, 4.005R",
    imagesReady: Array.from(document.images, (i) => i.complete && i.naturalWidth > 0),
    wordX: word.x,
    wordY: word.y,
    wordWidth: word.width,
    wordHeight: word.height,
    quote: target.textContent,
    href: "OEBPS/chapter.xhtml#target",
    prefix: "At the next gate, the reader stops to write.",
    suffix: "After capture, remove the local source copy and restart the app.",
  };
}
