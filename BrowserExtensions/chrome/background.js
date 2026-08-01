const NATIVE_HOST = "com.audiofocus.nativehost";
const BROWSER_BUNDLE_ID = "com.google.Chrome";
const FADE_MS = 450;
const RUNNING_RECONNECT_MS = 2000;
const STOPPED_RECONNECT_MS = 5000;
let controllerEnabled = false;
let nativePort = null;
let configTimer = null;
let reconnectTimer = null;
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

  const restoreTabIDs = [...tabsToRestore];
  tabsToRestore.clear();
  for (const tabId of restoreTabIDs) {
    try { await chrome.tabs.update(tabId, { muted: false }); } catch (_) {}
    await sendFade(tabId, "in");
  }
  managedTabs.clear();
  tabActivity.clear();
}

async function enableController() {
  if (controllerEnabled) return;
  controllerEnabled = true;
  await sendTabState();
}

function connectNativeHost() {
  if (nativePort) return;
  try {
    const port = chrome.runtime.connectNative(NATIVE_HOST);
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
    await chrome.tabs.sendMessage(tabId, {
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
  managedTabs.add(tabId);
  tabsToRestore.add(tabId);
  await sendFade(tabId, "out");
  setTimeout(async () => {
    try { await chrome.tabs.update(tabId, { muted: true }); } catch (_) {}
  }, FADE_MS);
}

async function fadeIn(tabId) {
  if (!controllerEnabled) return;
  managedTabs.add(tabId);
  try { await chrome.tabs.update(tabId, { muted: false }); } catch (_) { return; }
  await sendFade(tabId, "in");
  tabsToRestore.delete(tabId);
}

async function mediaIsPlaying(tabId) {
  try {
    const frames = await chrome.webNavigation.getAllFrames({ tabId });
    const responses = await Promise.all(frames.map(async ({ frameId }) => {
      try {
        return await chrome.tabs.sendMessage(
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
      const response = await chrome.tabs.sendMessage(tabId, { type: "audiofocus-media-state" });
      return typeof response?.playing === "boolean" ? response.playing : null;
    } catch (_) {
      return null;
    }
  }
}

async function buildTabSnapshot() {
  const [activeWindow] = await chrome.windows.getAll({ populate: true, windowTypes: ["normal"] });
  const tabs = activeWindow?.tabs ?? [];
  const activeTab = tabs.find(tab => tab.active) || tabs[0] || null;
  const windowFocused = Boolean(activeWindow?.focused);

  for (const tab of tabs) {
    noteTabActivity(tab, tab.id === activeTab?.id);
  }

  const snapshotTabs = await Promise.all(tabs.map(async (tab) => {
    const activity = tabActivity.get(tab.id) || { lastAudibleAt: 0, lastFocusedAt: 0 };
    const playing = tab.audible ? null : await mediaIsPlaying(tab.id);
    return {
      id: tab.id,
      audible: tab.audible,
      muted: tab.mutedInfo?.muted ?? false,
      playing,
      lastFocusedAt: activity.lastFocusedAt || 0,
      lastAudibleAt: activity.lastAudibleAt || 0
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
  if (!controllerEnabled || !nativePort) return;
  try {
    nativePort.postMessage(await buildTabSnapshot());
  } catch (_) {}
}

async function applyStateCommand(message) {
  if (!controllerEnabled) return;
  if (message.muteAll === true) {
    const tabs = await chrome.tabs.query({});
    for (const tab of tabs) {
      if (tab.audible || managedTabs.has(tab.id)) {
        await fadeOutAndMute(tab.id);
      }
    }
    return;
  }

  for (const action of message.actions ?? []) {
    if (action.kind === "unmute") {
      await fadeIn(action.tabID);
    } else if (action.kind === "mute") {
      await fadeOutAndMute(action.tabID);
    }
  }
}

async function muteAllLocally() {
  const tabs = await chrome.tabs.query({});
  for (const tab of tabs) {
    if (tab.audible || managedTabs.has(tab.id)) {
      await fadeOutAndMute(tab.id);
    }
  }
}

chrome.tabs.onActivated.addListener(async () => {
  if (!controllerEnabled) return;
  await sendTabState();
});

chrome.tabs.onUpdated.addListener(async (_tabId, changeInfo, tab) => {
  if (!controllerEnabled) return;
  if (changeInfo.audible !== undefined || changeInfo.mutedInfo !== undefined || (tab.active && tab.audible)) {
    noteTabActivity(tab);
    await sendTabState();
  }
});

chrome.windows.onFocusChanged.addListener(async (windowId) => {
  if (!controllerEnabled) return;
  if (windowId === chrome.windows.WINDOW_ID_NONE) {
    await muteAllLocally();
    return;
  }
  await sendTabState();
});

chrome.tabs.onRemoved.addListener(async (tabId) => {
  managedTabs.delete(tabId);
  tabsToRestore.delete(tabId);
  tabActivity.delete(tabId);
  if (controllerEnabled) await sendTabState();
});

async function initialize() {
  connectNativeHost();
  setInterval(() => sendTabState(), 1000);
}

initialize();
