const NATIVE_HOST = "com.audiofocus.nativehost";
const BROWSER_BUNDLE_ID = "org.mozilla.firefox";
const FADE_MS = 450;
const OWNER_CLOSE_DEBOUNCE_MS = 250;
const OWNER_RECOVERY_ATTEMPTS = 8;
const FALLBACK_AUDIBLE_GRACE_MS = 15000;
const RUNNING_RECONNECT_MS = 2000;
const STOPPED_RECONNECT_MS = 5000;
let switchDelayMs = 500;
let controllerEnabled = false;
let ownerTabId = null;
let switchSerial = 0;
let candidateSerial = 0;
let recoverySerial = 0;
let nativePort = null;
let configTimer = null;
let reconnectTimer = null;
let reportedOwnerCloseSerial = null;
const managedTabs = new Set();
const tabsToRestore = new Set();
const tabActivity = new Map();

function noteTabActivity(tab, focused = false) {
  if (!tab?.id) return;
  const activity = tabActivity.get(tab.id) || { lastAudibleAt: 0, lastFocusedAt: 0 };
  if (tab.audible) activity.lastAudibleAt = Date.now();
  if (focused) activity.lastFocusedAt = Date.now();
  tabActivity.set(tab.id, activity);
}

function requestConfig() {
  try { nativePort?.postMessage({ type: "get_config" }); } catch (_) {}
}

function reportBrowserAudioEvent(type) {
  try {
    nativePort?.postMessage({ type, browserBundleID: BROWSER_BUNDLE_ID });
  } catch (_) {}
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

async function disableController() {
  if (!controllerEnabled && !tabsToRestore.size) return;
  controllerEnabled = false;
  candidateSerial++;
  switchSerial++;
  recoverySerial++;
  ownerTabId = null;

  const restoreTabIDs = [...tabsToRestore];
  tabsToRestore.clear();
  for (const tabId of restoreTabIDs) {
    try { await browser.tabs.update(tabId, { muted: false }); } catch (_) {}
    await sendFade(tabId, "in");
  }
  managedTabs.clear();
  tabActivity.clear();
}

async function enableController() {
  if (controllerEnabled) return;
  controllerEnabled = true;
  const tabs = await browser.tabs.query({ audible: true });
  if (!tabs.length) return;
  tabs.sort((a, b) => (b.lastAccessed || 0) - (a.lastAccessed || 0));
  await considerTab(tabs.find(tab => tab.active) || tabs[0]);
}

function connectNativeHost() {
  if (nativePort) return;
  try {
    const port = browser.runtime.connectNative(NATIVE_HOST);
    nativePort = port;
    port.onMessage.addListener(async (message) => {
      if (message?.type !== "config") return;
      if (message.appRunning !== true) {
        await disableController();
        if (nativePort === port) closeNativePort();
        scheduleNativeReconnect(STOPPED_RECONNECT_MS);
        return;
      }

      await enableController();
      const nextDelay = Math.max(0, Number(message.switchDelay) || 0) * 1000;
      if (nextDelay !== switchDelayMs) {
        switchDelayMs = nextDelay;
        candidateSerial++;
        const [tab] = await browser.tabs.query({ active: true, lastFocusedWindow: true });
        await considerTab(tab);
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
  } catch (_) {}
}

async function fadeOutAndMute(tabId, serial) {
  if (!controllerEnabled || !tabId || tabId === ownerTabId) return;
  managedTabs.add(tabId);
  tabsToRestore.add(tabId);
  await sendFade(tabId, "out");
  setTimeout(async () => {
    if (!controllerEnabled || serial !== switchSerial || tabId === ownerTabId) return;
    try { await browser.tabs.update(tabId, { muted: true }); } catch (_) {}
  }, FADE_MS);
}

async function fadeIn(tabId) {
  if (!controllerEnabled) return;
  managedTabs.add(tabId);
  try { await browser.tabs.update(tabId, { muted: false }); } catch (_) { return; }
  await sendFade(tabId, "in");
  tabsToRestore.delete(tabId);
}

async function switchOwner(tab) {
  if (!controllerEnabled || !tab?.id || tab.id === ownerTabId) return;
  recoverySerial++;
  const serial = ++switchSerial;
  const previous = ownerTabId;
  ownerTabId = tab.id;

  await fadeIn(tab.id);
  reportBrowserAudioEvent("browser_owner_active");
  if (previous) await fadeOutAndMute(previous, serial);

  const tabs = await browser.tabs.query({});
  for (const other of tabs) {
    if (other.id !== ownerTabId && (other.audible || managedTabs.has(other.id))) {
      await fadeOutAndMute(other.id, serial);
    }
  }
}

async function candidateIsPlaying(tab) {
  if (!tab?.id) return false;
  if (tab.audible) {
    noteTabActivity(tab);
    return true;
  }
  if (!managedTabs.has(tab.id)) return false;
  return await mediaIsPlaying(tab.id) === true;
}

async function considerTab(tab, restoreExistingOwner = false) {
  const serial = ++candidateSerial;
  if (!controllerEnabled || !tab?.id || !tab.active) return;

  try {
    const window = await browser.windows.get(tab.windowId);
    if (!window.focused) return;
  } catch (_) { return; }

  noteTabActivity(tab, true);
  if (!await candidateIsPlaying(tab)) return;
  if (restoreExistingOwner && tab.id === ownerTabId) {
    await fadeIn(tab.id);
    reportBrowserAudioEvent("browser_owner_active");
    return;
  }

  setTimeout(async () => {
    if (!controllerEnabled || serial !== candidateSerial) return;
    try {
      const latest = await browser.tabs.get(tab.id);
      const window = await browser.windows.get(latest.windowId);
      if (latest.active && window.focused && await candidateIsPlaying(latest)) {
        await switchOwner(latest);
      }
    } catch (_) {}
  }, switchDelayMs);
}

async function mediaIsPlaying(tabId) {
  try {
    const frames = await browser.webNavigation.getAllFrames({ tabId });
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

async function isFallbackCandidate(tab) {
  if (!tab?.id) return false;
  if (tab.audible) {
    noteTabActivity(tab);
    return true;
  }

  const playing = await mediaIsPlaying(tab.id);
  if (playing !== null) return playing;

  const activity = tabActivity.get(tab.id);
  return managedTabs.has(tab.id)
    && Boolean(activity?.lastAudibleAt)
    && Date.now() - activity.lastAudibleAt <= FALLBACK_AUDIBLE_GRACE_MS;
}

async function recoverClosedOwner(serial, remainingAttempts) {
  if (!controllerEnabled || serial !== recoverySerial || ownerTabId !== null) return;

  try {
    const [foreground] = await browser.tabs.query({ active: true, lastFocusedWindow: true });
    if (foreground) {
      const window = await browser.windows.get(foreground.windowId);
      noteTabActivity(foreground, window.focused);
      if (window.focused && await isFallbackCandidate(foreground)) {
        await switchOwner(foreground);
        return;
      }
    }
  } catch (_) {}

  if (reportedOwnerCloseSerial !== serial) {
    reportedOwnerCloseSerial = serial;
    reportBrowserAudioEvent("browser_owner_closed");
  }

  if (remainingAttempts > 1) {
    setTimeout(
      () => recoverClosedOwner(serial, remainingAttempts - 1),
      OWNER_CLOSE_DEBOUNCE_MS
    );
  }
}

function scheduleOwnerRecovery() {
  const serial = ++recoverySerial;
  setTimeout(
    () => recoverClosedOwner(serial, OWNER_RECOVERY_ATTEMPTS),
    OWNER_CLOSE_DEBOUNCE_MS
  );
}

async function muteBrowserForBackground() {
  candidateSerial++;
  recoverySerial++;
  const serial = ++switchSerial;
  ownerTabId = null;

  const tabs = await browser.tabs.query({});
  for (const tab of tabs) {
    if (tab.audible || managedTabs.has(tab.id)) {
      await fadeOutAndMute(tab.id, serial);
    }
  }
}

browser.tabs.onActivated.addListener(async ({ tabId }) => {
  if (!controllerEnabled) return;
  try { await considerTab(await browser.tabs.get(tabId), true); } catch (_) {}
});

browser.tabs.onUpdated.addListener(async (_tabId, changeInfo, tab) => {
  if (!controllerEnabled) return;
  if (changeInfo.audible === true || (tab.active && tab.audible)) {
    noteTabActivity(tab);
    await considerTab(tab);
  }
});

browser.windows.onFocusChanged.addListener(async (windowId) => {
  if (!controllerEnabled) return;
  if (windowId === browser.windows.WINDOW_ID_NONE) {
    await muteBrowserForBackground();
    return;
  }
  candidateSerial++;
  const [tab] = await browser.tabs.query({ active: true, windowId });
  await considerTab(tab, true);
});

browser.tabs.onRemoved.addListener((tabId) => {
  const wasOwner = ownerTabId === tabId;
  managedTabs.delete(tabId);
  tabsToRestore.delete(tabId);
  tabActivity.delete(tabId);
  if (!wasOwner) return;
  ownerTabId = null;
  candidateSerial++;
  switchSerial++;
  scheduleOwnerRecovery();
});

(async () => {
  connectNativeHost();
})();
