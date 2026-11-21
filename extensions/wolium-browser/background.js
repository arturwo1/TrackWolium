const api = globalThis.browser ?? globalThis.chrome;
const ENDPOINT = "http://127.0.0.1:9095/v1/browser";
const PING_URL = "http://127.0.0.1:9095/v1/browser/top?days=1&limit=1";

let activeDomain = "";
let activeTitle = "";
let activeUrl = "";
let activeSince = 0;
let windowFocused = true;
let userIdle = false;
let paused = false;
let connected = false;
let lastError = "";

function detectBrowser() {
  const ua = (navigator.userAgent || "").toLowerCase();
  if (ua.includes("opr/") || ua.includes("opera")) return "opera";
  if (ua.includes("edg/")) return "edge";
  if (ua.includes("vivaldi")) return "vivaldi";
  if (ua.includes("yabrowser")) return "yandex";
  if (ua.includes("firefox") || ua.includes("librewolf") || ua.includes("floorp") || ua.includes("waterfox") || ua.includes("zen")) return "firefox";
  if (navigator.brave) return "brave";
  if (ua.includes("chromium")) return "chromium";
  return "chrome";
}

function extractDomain(rawUrl) {
  if (!rawUrl || typeof rawUrl !== "string") return "";
  try {
    const u = new URL(rawUrl);
    if (u.protocol !== "http:" && u.protocol !== "https:") return "";
    let host = (u.hostname || "").toLowerCase();
    if (host.startsWith("www.")) host = host.slice(4);
    if (!host || host.length > 192) return "";
    return u.port && host === "localhost" ? `${host}:${u.port}` : host;
  } catch {
    return "";
  }
}

function cleanUrl(rawUrl) {
  if (!rawUrl || typeof rawUrl !== "string") return "";
  try {
    const u = new URL(rawUrl);
    if (u.protocol !== "http:" && u.protocol !== "https:") return "";
    return u.href.slice(0, 512);
  } catch {
    return "";
  }
}

function cleanTitle(rawTitle) {
  if (!rawTitle || typeof rawTitle !== "string") return "";
  return rawTitle.replace(/\s+/g, " ").trim().slice(0, 180);
}

async function postUsage(domain, title, url, ms) {
  if (!domain || ms < 500) return;
  const clamped = Math.min(Math.round(ms), 120000);
  try {
    const res = await fetch(ENDPOINT, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        browser: detectBrowser(),
        domain,
        title: title || "",
        url: url || "",
        ms: clamped,
      }),
    });
    connected = res.ok;
    lastError = res.ok ? "" : `HTTP ${res.status}`;
  } catch (err) {
    connected = false;
    lastError = String(err && err.message ? err.message : "offline");
  }
}

async function flush() {
  const now = Date.now();
  if (paused || !windowFocused || userIdle || !activeDomain || !activeSince) {
    activeSince = paused || !windowFocused || userIdle ? 0 : now;
    return;
  }
  const delta = now - activeSince;
  activeSince = now;
  if (delta >= 1000) {
    await postUsage(activeDomain, activeTitle, activeUrl, delta);
  }
}

async function refreshActiveTab() {
  await flush();
  if (paused || !windowFocused || userIdle) {
    activeSince = 0;
    return;
  }
  try {
    const tabs = await api.tabs.query({ active: true, lastFocusedWindow: true });
    const tab = tabs && tabs[0];
    const domain = tab ? extractDomain(tab.url) : "";
    activeDomain = domain;
    activeTitle = domain && tab ? cleanTitle(tab.title) : "";
    activeUrl = domain && tab ? cleanUrl(tab.url) : "";
    activeSince = domain ? Date.now() : 0;
  } catch {
    activeDomain = "";
    activeTitle = "";
    activeUrl = "";
    activeSince = 0;
  }
}

async function checkConnection() {
  try {
    const res = await fetch(PING_URL);
    connected = res.ok;
    lastError = res.ok ? "" : `HTTP ${res.status}`;
  } catch {
    connected = false;
    lastError = "offline";
  }
}

api.storage.local.get({ paused: false }, (res) => {
  paused = Boolean(res && res.paused);
  refreshActiveTab();
  checkConnection();
});

api.tabs.onActivated.addListener(() => {
  refreshActiveTab();
});

api.tabs.onUpdated.addListener((_tabId, changeInfo, tab) => {
  if (!tab || !tab.active) return;
  if (changeInfo.url || changeInfo.status === "complete") {
    refreshActiveTab();
  } else if (changeInfo.title) {
    const dom = extractDomain(tab.url);
    if (dom && dom === activeDomain) {
      activeTitle = cleanTitle(changeInfo.title);
      activeUrl = cleanUrl(tab.url);
    } else {
      refreshActiveTab();
    }
  }
});

api.windows.onFocusChanged.addListener((winId) => {
  windowFocused = winId !== api.windows.WINDOW_ID_NONE;
  refreshActiveTab();
});

if (api.idle && api.idle.setDetectionInterval) {
  api.idle.setDetectionInterval(60);
  api.idle.onStateChanged.addListener((state) => {
    userIdle = state !== "active";
    refreshActiveTab();
  });
}

if (api.alarms) {
  api.alarms.create("wolium-flush", { periodInMinutes: 0.25 });
  api.alarms.onAlarm.addListener((alarm) => {
    if (alarm.name === "wolium-flush") flush();
  });
}

api.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  if (!msg || typeof msg !== "object") return false;
  if (msg.type === "status") {
    flush().then(async () => {
      if (!connected) await checkConnection();
      sendResponse({
        browser: detectBrowser(),
        domain: activeDomain,
        title: activeTitle,
        url: activeUrl,
        paused,
        connected,
        lastError,
      });
    });
    return true;
  }
  if (msg.type === "togglePause") {
    flush().then(() => {
      paused = !paused;
      api.storage.local.set({ paused }, () => {
        refreshActiveTab();
        sendResponse({ paused });
      });
    });
    return true;
  }
  return false;
});
