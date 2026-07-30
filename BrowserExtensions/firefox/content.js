const mediaState = new WeakMap();

function fadeMedia(element, direction, duration) {
  let state = mediaState.get(element);
  if (!state) {
    state = { volume: element.volume, muted: element.muted };
    mediaState.set(element, state);
  }

  if (direction === "out") {
    state.volume = element.volume > 0 ? element.volume : state.volume;
    state.muted = element.muted;
  } else if (!state.muted) {
    element.muted = false;
  }

  const from = element.volume;
  const to = direction === "out" ? 0 : Math.max(0, Math.min(1, state.volume));
  const started = performance.now();

  function step(now) {
    const progress = Math.min(1, (now - started) / duration);
    const eased = progress * progress * (3 - 2 * progress);
    element.volume = from + (to - from) * eased;
    if (progress < 1) requestAnimationFrame(step);
  }
  requestAnimationFrame(step);
}

browser.runtime.onMessage.addListener((message) => {
  if (message?.type !== "audiofocus-fade") return;
  document.querySelectorAll("audio, video").forEach(element => {
    fadeMedia(element, message.direction, message.duration || 450);
  });
});
