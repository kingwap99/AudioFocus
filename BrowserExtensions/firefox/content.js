const mediaState = new WeakMap();
const FADE_FLOOR = 0.01;

function fadeMedia(element, direction, duration) {
  let state = mediaState.get(element);
  if (!state) {
    state = {
      volume: element.volume,
      muted: element.muted,
      generation: 0,
      direction: null
    };
    mediaState.set(element, state);
  }

  if (direction === "out") {
    // Only remember this as the "real" volume when it is a genuine playback
    // level, never our own faded-down floor. Otherwise a second consecutive
    // fade-out would lock in 0.01 and every later fade-in would restore to
    // "1格" — the exact bug we are fixing.
    if (state.direction === null && element.volume > FADE_FLOOR * 2) {
      state.volume = element.volume;
    }
    state.muted = element.muted;
  } else if (!state.muted) {
    element.muted = false;
  }

  const generation = ++state.generation;
  state.direction = direction;
  const from = element.volume;
  const savedVolume = Math.max(0, Math.min(1, state.volume));
  // Fade-out drives volume down toward the floor. Fade-in restores the
 // remembered genuine level (savedVolume). The recording guard above keeps
 // savedVolume from ever being corrupted to our own floor, so this never
 // snaps the page back to "1格".
  const to = direction === "out"
    ? (savedVolume > 0 ? Math.min(FADE_FLOOR, savedVolume) : 0)
    : Math.max(savedVolume, element.volume);
  const started = performance.now();
  const fadeDuration = Math.max(1, duration);

  function step(now) {
    if (generation !== state.generation) return;
    const progress = Math.min(1, (now - started) / fadeDuration);
    const eased = progress * progress * (3 - 2 * progress);
    element.volume = from + (to - from) * eased;
    if (progress < 1) {
      requestAnimationFrame(step);
    } else {
      element.volume = to;
      if (direction === "in" && !state.muted) element.muted = false;
      state.direction = null;
    }
  }
  requestAnimationFrame(step);
}

browser.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message?.type === "audiofocus-media-state") {
    const playing = Array.from(document.querySelectorAll("audio, video"))
      .some(element => !element.paused && !element.ended);
    sendResponse({ playing });
    return;
  }
  if (message?.type !== "audiofocus-fade") return;
  document.querySelectorAll("audio, video").forEach(element => {
    fadeMedia(element, message.direction, message.duration || 450);
  });
});
