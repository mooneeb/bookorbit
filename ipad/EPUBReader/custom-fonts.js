import { fontPrefixes, fontCSSFormats } from "./font-vocabulary.js";

let loadedFaces = [];
let rules = "";
let configured;
let generation = 0;
const cssWeight = (value) => Number.isInteger(value) && value >= 1 && value <= 1000;
const customFamily = (family) => typeof family === "string" && Object.values(fontPrefixes).some((prefix) => family.startsWith(prefix));

export const prepareCustomFonts = async (faces, settings, publicationDocuments) => {
  const request = ++generation;
  if (!Array.isArray(faces) || faces.length > 4) throw new Error("The selected font family exceeds the resource limit.");
  const family = settings.fontFamily;
  if (!faces.length) {
    if (customFamily(family)) throw new Error("The selected custom font is unavailable.");
    clearCustomFonts();
    return true;
  }
  if (
    !customFamily(family) ||
    !/^[a-z0-9_]{1,220}$/.test(family) ||
    !cssWeight(settings.fontWeight) ||
    !["normal", "italic"].includes(settings.fontStyle)
  )
    throw new Error("The custom font selection is invalid.");
  if (typeof FontFace !== "function" || !document.fonts) throw new Error("Custom font loading is unsupported on this device.");
  if (!Array.isArray(publicationDocuments) || !publicationDocuments.length || publicationDocuments.length > 2)
    throw new Error("The live publication font context is unavailable.");
  const pendingFaces = [];
  const publicationFaces = [];
  const nextRules = [];
  let selectedSource;
  for (const face of faces) {
    const url = new URL(face.url);
    const weights = String(face.weight).split(" ").map(Number);
    if (
      face.family !== family ||
      url.protocol !== "bookorbit-font:" ||
      !/^[0-9a-f-]{36}$/.test(url.hostname) ||
      !/^\/[0-9a-f-]{36}$/.test(url.pathname) ||
      url.search ||
      url.hash ||
      url.username ||
      url.password ||
      url.port ||
      !Object.values(fontCSSFormats).includes(face.format) ||
      weights.length < 1 ||
      weights.length > 2 ||
      !weights.every(cssWeight) ||
      (weights.length === 2 && weights[0] >= weights[1]) ||
      !Array.isArray(face.styles) ||
      !face.styles.length ||
      face.styles.length > 2 ||
      !face.styles.every((style) => ["normal", "italic"].includes(style))
    )
      throw new Error("The custom font resource is invalid.");
    for (const style of face.styles) {
      const source = `url(${JSON.stringify(url.href)}) format(${JSON.stringify(face.format)})`;
      const font = new FontFace(family, source, { weight: face.weight, style, display: "block" });
      pendingFaces.push(font);
      if (!selectedSource && style === settings.fontStyle && settings.fontWeight >= weights[0] && settings.fontWeight <= weights[weights.length - 1])
        selectedSource = { source, weight: face.weight, style };
      nextRules.push(
        `@font-face { font-family: ${JSON.stringify(family)}; src: ${source}; font-weight: ${face.weight}; font-style: ${style}; font-display: block; }`,
      );
    }
  }
  if (!selectedSource) throw new Error("The selected custom font variant is unavailable.");
  for (const doc of publicationDocuments) {
    const Constructor = doc.defaultView?.FontFace;
    if (typeof Constructor !== "function" || !doc.fonts) throw new Error("Custom fonts are unsupported in this publication.");
    publicationFaces.push(
      new Constructor(family, selectedSource.source, { weight: selectedSource.weight, style: selectedSource.style, display: "block" }),
    );
  }
  let timeout;
  try {
    await Promise.race([
      Promise.all([...pendingFaces, ...publicationFaces].map((font) => font.load())),
      new Promise((_, reject) => {
        timeout = setTimeout(() => reject(new Error("Custom font loading timed out.")), 130000);
      }),
    ]);
    if (request !== generation || [...pendingFaces, ...publicationFaces].some((font) => font.status !== "loaded"))
      throw new Error("Custom font loading was cancelled or failed.");
    for (const font of loadedFaces) document.fonts.delete(font);
    for (const font of pendingFaces) document.fonts.add(font);
    loadedFaces = pendingFaces;
    rules = nextRules.join("\n");
    return true;
  } finally {
    clearTimeout(timeout);
  }
};

export const configureCustomFont = (settings, formatting) => {
  configured = formatting && customFamily(settings.fontFamily) ? { ...settings } : null;
};
export const customFontCSS = () => rules;
export const settleCustomFonts = async (doc) => {
  if (!configured) return;
  const sample = (doc.body?.textContent ?? "Aa").slice(0, 256) || "Aa";
  const query = `${configured.fontStyle} ${configured.fontWeight} ${configured.fontSize}px ${JSON.stringify(configured.fontFamily)}`;
  const faces = await doc.fonts.load(query, sample);
  if (!faces.length || faces.some((font) => font.status !== "loaded")) throw new Error("The selected custom face could not be loaded in the book.");
};
export const clearCustomFonts = () => {
  generation++;
  for (const font of loadedFaces) document.fonts.delete(font);
  loadedFaces = [];
  rules = "";
  configured = null;
};
