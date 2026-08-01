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
    if (state.direction === null && element.volume > 0) {
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
  const to = direction === "out"
    ? (savedVolume > 0 ? Math.min(FADE_FLOOR, savedVolume) : 0)
    : savedVolume;
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

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
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
