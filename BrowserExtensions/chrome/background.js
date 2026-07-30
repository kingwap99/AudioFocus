const FADE_MS = 450;
let ownerTabId = null;
let switchSerial = 0;
const managedTabs = new Set();

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

async function fadeOutAndMute(tabId, serial) {
  if (!tabId || tabId === ownerTabId) return;
  managedTabs.add(tabId);
  await sendFade(tabId, "out");
  setTimeout(async () => {
    if (serial !== switchSerial || tabId === ownerTabId) return;
    try { await chrome.tabs.update(tabId, { muted: true }); } catch (_) {}
  }, FADE_MS);
}

async function fadeIn(tabId) {
  managedTabs.add(tabId);
  try { await chrome.tabs.update(tabId, { muted: false }); } catch (_) { return; }
  await sendFade(tabId, "in");
}

async function switchOwner(tab) {
  if (!tab || !tab.id || tab.id === ownerTabId) return;
  const serial = ++switchSerial;
  const previous = ownerTabId;
  ownerTabId = tab.id;

  await fadeIn(tab.id);
  if (previous) await fadeOutAndMute(previous, serial);

  // Enforce one audible owner even when multiple tabs started before the extension.
  const tabs = await chrome.tabs.query({});
  for (const other of tabs) {
    if (other.id !== ownerTabId && (other.audible || managedTabs.has(other.id))) {
      await fadeOutAndMute(other.id, serial);
    }
  }
}

async function considerTab(tab) {
  if (!tab || !tab.id || !tab.active || !tab.audible) return;
  try {
    const window = await chrome.windows.get(tab.windowId);
    if (window.focused) await switchOwner(tab);
  } catch (_) {}
}

chrome.tabs.onActivated.addListener(async ({ tabId }) => {
  try { await considerTab(await chrome.tabs.get(tabId)); } catch (_) {}
});

chrome.tabs.onUpdated.addListener(async (_tabId, changeInfo, tab) => {
  if (changeInfo.audible === true || (tab.active && tab.audible)) {
    await considerTab(tab);
  }
});

chrome.windows.onFocusChanged.addListener(async (windowId) => {
  if (windowId === chrome.windows.WINDOW_ID_NONE) return;
  const [tab] = await chrome.tabs.query({ active: true, windowId });
  await considerTab(tab);
});

chrome.tabs.onRemoved.addListener((tabId) => {
  managedTabs.delete(tabId);
  if (ownerTabId === tabId) ownerTabId = null;
});

async function initialize() {
  const tabs = await chrome.tabs.query({ audible: true });
  if (!tabs.length) return;
  tabs.sort((a, b) => (b.lastAccessed || 0) - (a.lastAccessed || 0));
  const activeAudible = tabs.find(tab => tab.active) || tabs[0];
  await switchOwner(activeAudible);
}

initialize();
