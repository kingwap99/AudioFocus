// AudioFocus tab controller — pure sensor/actuator (decision-core design §5/§6).
// Reports tab facts (audible / playing / mutedByUs) and executes the app's
// state_commands. All ownership decisions live in the macOS app; this worker
// never decides which tab should be audible.
const NATIVE_HOST = "com.audiofocus.nativehost";
const BROWSER_BUNDLE_ID = "org.mozilla.firefox";
const FADE_MS = 450;
const RUNNING_RECONNECT_MS = 2000;
const STOPPED_RECONNECT_MS = 5000;

let controllerEnabled = false;
let nativePort = null;
let configTimer = null;
let reconnectTimer = null;
let snapshotInFlight = false;
let stateLoaded = false;

// Mute bookkeeping. Persisted to browser.storage.session so a service-worker
// restart cannot lose track of which tabs we muted (and must restore).
let mutedByUs = new Set();
let mutedByUser = new Set();

async function loadState() {
  try {
    const stored = await browser.storage.session.get(["mutedByUs", "mutedByUser"]);
    mutedByUs = new Set(stored.mutedByUs || []);
    mutedByUser = new Set(stored.mutedByUser || []);
  } catch (_) {}
  stateLoaded = true;
}

function saveState() {
  try {
    browser.storage.session.set({
      mutedByUs: [...mutedByUs],
      mutedByUser: [...mutedByUser]
    });
  } catch (_) {}
}

function requestConfig() {
  try { nativePort?.postMessage({ type: "get_config" }); } catch (_) {}
}

function stopConfigPolling() {
  if (configTimer) clearInterval(configTimer);
  configTimer = null;
}

function scheduleNativeReconnect(delay) {
  if (nativePort || reconnectTimer) return;
  reconnectTimer = setTimeout(() => {
    reconnectTimer = null;
    connectNativeHost();
  }, delay);
}

function closeNativePort() {
  const port = nativePort;
  nativePort = null;
  stopConfigPolling();
  try { port?.disconnect(); } catch (_) {}
}

// App stopped: restore every tab we muted so nothing stays silent.
async function disableController() {
  if (!stateLoaded) await loadState();
  if (!controllerEnabled && !mutedByUs.size) return;
  controllerEnabled = false;

  const restoreTabIDs = [...mutedByUs];
  mutedByUs.clear();
  saveState();
  for (const tabId of restoreTabIDs) {
    try { await browser.tabs.update(tabId, { muted: false }); } catch (_) {}
    await sendFade(tabId, "in");
  }
}

async function enableController() {
  if (controllerEnabled) return;
  controllerEnabled = true;
  await sendTabState();
}

function connectNativeHost() {
  if (nativePort) return;
  try {
    const port = browser.runtime.connectNative(NATIVE_HOST);
    nativePort = port;
    port.onMessage.addListener(async (message) => {
      if (message?.type === "config") {
        if (message.appRunning !== true) {
          await disableController();
          if (nativePort === port) closeNativePort();
          scheduleNativeReconnect(STOPPED_RECONNECT_MS);
          return;
        }
        await enableController();
      } else if (message?.type === "state_command") {
        await applyStateCommand(message);
      }
    });
    port.onDisconnect.addListener(() => {
      if (nativePort !== port) return;
      nativePort = null;
      stopConfigPolling();
      scheduleNativeReconnect(
        controllerEnabled ? RUNNING_RECONNECT_MS : STOPPED_RECONNECT_MS
      );
    });
    requestConfig();
    stopConfigPolling();
    configTimer = setInterval(requestConfig, 1000);
  } catch (_) {
    nativePort = null;
    stopConfigPolling();
    scheduleNativeReconnect(
      controllerEnabled ? RUNNING_RECONNECT_MS : STOPPED_RECONNECT_MS
    );
  }
}

async function sendFade(tabId, direction) {
  try {
    await browser.tabs.sendMessage(tabId, {
      type: "audiofocus-fade",
      direction,
      duration: FADE_MS
    });
  } catch (_) {
    // Restricted pages and WebAudio cannot be faded by a content script.
  }
}

async function fadeOutAndMute(tabId) {
  if (!controllerEnabled || !tabId) return;
  if (mutedByUser.has(tabId)) return;
  if (mutedByUs.has(tabId)) {
    try { await browser.tabs.update(tabId, { muted: true }); } catch (_) {}
    return;
  }
  try {
    const tab = await browser.tabs.get(tabId);
    if (tab?.mutedInfo?.muted) {
      // The user muted this tab themselves; never touch it.
      mutedByUser.add(tabId);
      saveState();
      return;
    }
  } catch (_) {
    return;
  }
  mutedByUs.add(tabId);
  saveState();
  await sendFade(tabId, "out");
  setTimeout(async () => {
    try { await browser.tabs.update(tabId, { muted: true }); } catch (_) {}
  }, FADE_MS);
}

async function fadeIn(tabId) {
  if (!controllerEnabled || !tabId) return;
  if (mutedByUser.has(tabId)) return;
  mutedByUs.delete(tabId);
  saveState();
  try { await browser.tabs.update(tabId, { muted: false }); } catch (_) { return; }
  await sendFade(tabId, "in");
}

async function mediaIsPlaying(tabId) {
  try {
    const frames = await browser.webNavigation.getAllFrames({ tabId });
    if (!Array.isArray(frames) || frames.length === 0) return null;
    const responses = await Promise.all(frames.map(async ({ frameId }) => {
      try {
        return await browser.tabs.sendMessage(
          tabId,
          { type: "audiofocus-media-state" },
          { frameId }
        );
      } catch (_) {
        return null;
      }
    }));
    const states = responses
      .map(response => response?.playing)
      .filter(playing => typeof playing === "boolean");
    return states.length ? states.some(Boolean) : null;
  } catch (_) {
    try {
      const response = await browser.tabs.sendMessage(tabId, { type: "audiofocus-media-state" });
      return typeof response?.playing === "boolean" ? response.playing : null;
    } catch (_) {
      return null;
    }
  }
}

async function buildTabSnapshot() {
  const windows = await browser.windows.getAll({ populate: true, windowTypes: ["normal"] });
  const activeWindow = (windows || []).find(window => window.focused) || (windows || [])[0] || null;
  if (!activeWindow) return null;
  const tabs = activeWindow?.tabs ?? [];
  const activeTab = tabs.find(tab => tab.active) || tabs[0] || null;
  const windowFocused = Boolean(activeWindow.focused);

  const snapshotTabs = await Promise.all(tabs.map(async (tab) => {
    // `playing` is the anti-feedback eligibility signal (design §5): it reflects
    // the page's media elements, never the mute state we imposed.
    const playing = tab.audible ? null : await mediaIsPlaying(tab.id);
    return {
      id: tab.id,
      audible: tab.audible,
      muted: tab.mutedInfo?.muted ?? false,
      mutedByUs: mutedByUs.has(tab.id),
      playing
    };
  }));

  return {
    type: "tab_state",
    browserBundleID: BROWSER_BUNDLE_ID,
    contextID: "default",
    activeTabID: activeTab?.id ?? -1,
    windowFocused,
    tabs: snapshotTabs
  };
}

async function sendTabState() {
  if (!controllerEnabled || !nativePort || snapshotInFlight) return;
  snapshotInFlight = true;
  try {
    const snapshot = await buildTabSnapshot();
    if (snapshot) nativePort.postMessage(snapshot);
  } catch (_) {
    // Restricted pages or a disappearing window can break one snapshot; the
    // next tick retries instead of letting the service worker crash.
  } finally {
    snapshotInFlight = false;
  }
}

async function applyStateCommand(message) {
  if (!controllerEnabled) return;
  if (!stateLoaded) await loadState();

  console.log("[AudioFocus] state_command", JSON.stringify({
    muteAll: message.muteAll === true,
    noAction: message.noAction === true,
    actions: message.actions
  }));
  const actions = message.actions ?? [];
  const unmuteAction = actions.find(action => action.kind === "unmute");
  const muteOthers = actions.find(action => action.kind === "muteOthers");

  if (message.muteAll === true) {
    const tabs = await browser.tabs.query({});
    for (const tab of tabs) {
      if (tab.audible || mutedByUs.has(tab.id)) {
        await fadeOutAndMute(tab.id);
      }
    }
    return;
  }

  if (muteOthers) {
    const tabs = await browser.tabs.query({});
    for (const tab of tabs) {
      if (tab.id === muteOthers.tabID) continue;
      if (tab.audible && !mutedByUs.has(tab.id)) {
        await fadeOutAndMute(tab.id);
      } else if (mutedByUs.has(tab.id) && !tab.mutedInfo?.muted) {
        await browser.tabs.update(tab.id, { muted: true }).catch(() => {});
      }
    }
  }

  for (const action of actions) {
    if (action.kind === "mute") {
      await fadeOutAndMute(action.tabID);
    }
  }

  if (unmuteAction) {
    if (mutedByUs.has(unmuteAction.tabID)) {
      await fadeIn(unmuteAction.tabID);
    } else {
      try { await browser.tabs.update(unmuteAction.tabID, { muted: false }); } catch (_) {}
    }
  }
}

browser.tabs.onActivated.addListener(() => {
  if (controllerEnabled) sendTabState().catch(() => {});
});

browser.tabs.onUpdated.addListener((_tabId, changeInfo, tab) => {
  if (!controllerEnabled) return;
  if (changeInfo.audible !== undefined || changeInfo.mutedInfo !== undefined || (tab.active && tab.audible)) {
    sendTabState().catch(() => {});
  }
});

browser.windows.onFocusChanged.addListener(() => {
  if (controllerEnabled) sendTabState().catch(() => {});
});

browser.tabs.onRemoved.addListener((tabId) => {
  if (mutedByUs.delete(tabId) || mutedByUser.delete(tabId)) saveState();
  if (controllerEnabled) sendTabState().catch(() => {});
});

async function initialize() {
  await loadState();
  connectNativeHost();
  setInterval(() => {
    if (controllerEnabled) sendTabState().catch(() => {});
  }, 1000);
}

initialize();
