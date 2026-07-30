const NATIVE_HOST = "com.audiofocus.nativehost";
const FADE_MS = 450;
let switchDelayMs = 500;
let ownerTabId = null;
let switchSerial = 0;
let candidateSerial = 0;
let nativePort = null;
let configTimer = null;
const managedTabs = new Set();

function requestConfig() {
  try { nativePort?.postMessage({ type: "get_config" }); } catch (_) {}
}

function connectNativeHost() {
  try {
    nativePort = browser.runtime.connectNative(NATIVE_HOST);
    nativePort.onMessage.addListener(async (message) => {
      if (message?.type !== "config") return;
      const nextDelay = Math.max(0, Number(message.switchDelay) || 0) * 1000;
      if (nextDelay !== switchDelayMs) {
        switchDelayMs = nextDelay;
        candidateSerial++;
        const [tab] = await browser.tabs.query({ active: true, lastFocusedWindow: true });
        await considerTab(tab);
      }
    });
    nativePort.onDisconnect.addListener(() => {
      nativePort = null;
      if (configTimer) clearInterval(configTimer);
      configTimer = null;
      setTimeout(connectNativeHost, 2000);
    });
    requestConfig();
    configTimer = setInterval(requestConfig, 1000);
  } catch (_) {
    setTimeout(connectNativeHost, 2000);
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
  if (!tabId || tabId === ownerTabId) return;
  managedTabs.add(tabId);
  await sendFade(tabId, "out");
  setTimeout(async () => {
    if (serial !== switchSerial || tabId === ownerTabId) return;
    try { await browser.tabs.update(tabId, { muted: true }); } catch (_) {}
  }, FADE_MS);
}

async function fadeIn(tabId) {
  managedTabs.add(tabId);
  try { await browser.tabs.update(tabId, { muted: false }); } catch (_) { return; }
  await sendFade(tabId, "in");
}

async function switchOwner(tab) {
  if (!tab?.id || tab.id === ownerTabId) return;
  const serial = ++switchSerial;
  const previous = ownerTabId;
  ownerTabId = tab.id;

  await fadeIn(tab.id);
  if (previous) await fadeOutAndMute(previous, serial);

  const tabs = await browser.tabs.query({});
  for (const other of tabs) {
    if (other.id !== ownerTabId && (other.audible || managedTabs.has(other.id))) {
      await fadeOutAndMute(other.id, serial);
    }
  }
}

async function considerTab(tab) {
  const serial = ++candidateSerial;
  if (!tab?.id || !tab.active || !tab.audible) return;

  try {
    const window = await browser.windows.get(tab.windowId);
    if (!window.focused) return;
  } catch (_) { return; }

  setTimeout(async () => {
    if (serial !== candidateSerial) return;
    try {
      const latest = await browser.tabs.get(tab.id);
      const window = await browser.windows.get(latest.windowId);
      if (latest.active && latest.audible && window.focused) {
        await switchOwner(latest);
      }
    } catch (_) {}
  }, switchDelayMs);
}

browser.tabs.onActivated.addListener(async ({ tabId }) => {
  try { await considerTab(await browser.tabs.get(tabId)); } catch (_) {}
});

browser.tabs.onUpdated.addListener(async (_tabId, changeInfo, tab) => {
  if (changeInfo.audible === true || (tab.active && tab.audible)) {
    await considerTab(tab);
  }
});

browser.windows.onFocusChanged.addListener(async (windowId) => {
  candidateSerial++;
  if (windowId === browser.windows.WINDOW_ID_NONE) return;
  const [tab] = await browser.tabs.query({ active: true, windowId });
  await considerTab(tab);
});

browser.tabs.onRemoved.addListener((tabId) => {
  managedTabs.delete(tabId);
  if (ownerTabId === tabId) ownerTabId = null;
});

(async () => {
  connectNativeHost();
  const tabs = await browser.tabs.query({ audible: true });
  if (!tabs.length) return;
  tabs.sort((a, b) => (b.lastAccessed || 0) - (a.lastAccessed || 0));
  await considerTab(tabs.find(tab => tab.active) || tabs[0]);
})();
