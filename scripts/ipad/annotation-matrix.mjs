export const annotationProfiles = {
  "pro13-portrait-light": {
    viewport: { width: 1024, height: 1366 },
    orientation: "portrait",
    colorScheme: "light",
    dynamicType: "default",
    reducedMotion: "no-preference",
    nativeDevice: "iPad Pro 13-inch",
    window: "full",
  },
  "pro11-landscape-dark": {
    viewport: { width: 1194, height: 834 },
    orientation: "landscape",
    colorScheme: "dark",
    dynamicType: "default",
    reducedMotion: "no-preference",
    nativeDevice: "iPad Pro 11-inch",
    window: "full",
  },
  "pro11-portrait-large": {
    viewport: { width: 834, height: 1194 },
    orientation: "portrait",
    colorScheme: "light",
    dynamicType: "accessibilityExtraExtraExtraLarge",
    reducedMotion: "reduce",
    nativeDevice: "iPad Pro 11-inch",
    window: "full",
  },
  "pro13-narrow-dark": {
    viewport: { width: 600, height: 1024 },
    orientation: "landscape",
    colorScheme: "dark",
    dynamicType: "extraExtraExtraLarge",
    reducedMotion: "reduce",
    nativeDevice: "iPad Pro 13-inch",
    window: "narrow",
    nativeProfile: "pro13-landscape-dark-large",
  },
  "pro13-landscape-dark-large": {
    viewport: { width: 1366, height: 1024 },
    orientation: "landscape",
    colorScheme: "dark",
    dynamicType: "extraExtraExtraLarge",
    reducedMotion: "reduce",
    nativeDevice: "iPad Pro 13-inch",
    window: "full",
  },
};

export function annotationProfile(name = "pro13-portrait-light") {
  const profile = annotationProfiles[name];
  if (!profile) throw new Error(`Unknown annotation visual profile: ${name}`);
  return { name, ...profile };
}
