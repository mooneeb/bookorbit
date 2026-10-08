export const publicationPosition = (value) => {
  const total = value?.location?.total;
  const current = value?.location?.current;
  if (!Number.isSafeInteger(total) || total < 1 || !Number.isSafeInteger(current) || current < 0)
    return { locationNumber: null, locationTotal: null };
  return { locationNumber: Math.min(current + 1, total), locationTotal: total };
};

export const fractionTarget = (fraction) => {
  if (!Number.isFinite(fraction) || fraction < 0 || fraction > 1)
    throw new Error("Enter a percentage from 0 to 100 or a valid publication location.");
  return { fraction };
};

export const withProgrammaticMovement = async (renderer, smooth, action) => {
  const animated = renderer.hasAttribute("animated");
  if (smooth) renderer.setAttribute("animated", "");
  else renderer.removeAttribute("animated");
  try {
    return await action();
  } finally {
    if (animated) renderer.setAttribute("animated", "");
    else renderer.removeAttribute("animated");
  }
};
