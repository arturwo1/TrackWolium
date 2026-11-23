const api = globalThis.browser ?? globalThis.chrome;
const ENDPOINT = "http://127.0.0.1:9095/v1/browser";
const PING_URL = "http://127.0.0.1:9095/v1/browser/top?days=1&limit=1";
const SESSION_KEY = "woliumSessionState";

let state = {
  activeDomain: "",
  activeTitle: "",
  activeUrl: "",
  activeSince: 0,
  windowFocused: true,
  userIdle: false,
  paused: false,
  connected: false,
  lastError: "",
};

let loadPromise = null;
let opQueue = Promise.resolve();

function sessionStore() {
  return api.storage && api.storage.session ? api.storage.session : api.storage.local;
}

function storageGet(area, defaults) {
  return new Promise((resolve) => {
    try {
      area.get(defaults, (res) => resolve(res || defaults));
    } catch {
      resolve(defaults);
    }
  });
}

function storageSet(area, obj) {
  return new Promise((resolve) => {
    try {
      area.set(obj, () => resolve());
    } catch {
      resolve();
    }
  });
}

function ensureLoaded() {
  if (!loadPromise) {
    loadPromise = (async () => {
      const localRes = await storageGet(api.storage.local, { paused: false });
      const sessRes = await storageGet(sessionStore(), { [SESSION_KEY]: null });
      const saved = sessRes && sessRes[SESSION_KEY];
      if (saved && typeof saved === "object") {
        state.activeDomain = typeof saved.activeDomain === "string" ? saved.activeDomain : "";
        state.activeTitle = typeof saved.activeTitle === "string" ? saved.activeTitle : "";
        state.activeUrl = typeof saved.activeUrl === "string" ? saved.activeUrl : "";
        state.activeSince = Number.isFinite(saved.activeSince) ? saved.activeSince : 0;
        state.windowFocused = saved.windowFocused !== undefined ? Boolean(saved.windowFocused) : true;
        state.userIdle = Boolean(saved.userIdle);
        state.connected = Boolean(saved.connected);
        state.lastError = typeof saved.lastError === "string" ? saved.lastError : "";
      }
      state.paused = Boolean(localRes && localRes.paused);
    })();
  }
  return loadPromise;
}

function persistState() {
  return storageSet(sessionStore(), {
    [SESSION_KEY]: {
      activeDomain: state.activeDomain,
      activeTitle: state.activeTitle,
      activeUrl: state.activeUrl,
      activeSince: state.activeSince,
      windowFocused: state.windowFocused,
      userIdle: state.userIdle,
      connected: state.connected,
      lastError: state.lastError,
    },
  });
}

function serialized(fn) {
  opQueue = opQueue.then(() => ensureLoaded().then(fn)).catch(() => {});
  return opQueue;
}

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

function isPlaceholderTitle(title, domain, url) {
  const t = title.trim().toLowerCase();
  if (!t) return true;
  if (/^(https?|file|about|chrome|chrome-extension|edge|opera|brave|vivaldi|moz-extension):/i.test(t)) return true;
  const d = (domain || "").toLowerCase();
  const bare = d.startsWith("www.") ? d.slice(4) : d;
  if (d && (t === d || t === `www.${d}` || t === bare)) return true;
  if (d && (t.startsWith(`${d}/`) || t.startsWith(`www.${d}/`) || t.startsWith(`${bare}/`) || t.startsWith(`${d}:`) || t.startsWith(`www.${d}:`))) {
    return true;
  }
  if (!t.includes(" ") && /^[a-z0-9-]+(\.[a-z0-9-]+)+(:\d+)?(\/.*)?$/i.test(t)) return true;
  if (url) {
    const stripped = url.replace(/^https?:\/\//i, "").replace(/\/+$/, "").toLowerCase();
    const cleaned = t.replace(/\/+$/, "");
    if (cleaned === stripped || cleaned === `www.${stripped}`) return true;
  }
  return false;
}

function cleanTitle(rawTitle, domain = "", url = "") {
  if (!rawTitle || typeof rawTitle !== "string") return "";
  const t = rawTitle.replace(/\s+/g, " ").trim().slice(0, 180);
  if (isPlaceholderTitle(t, domain, url)) return "";
  return t;
}

async function postUsage(domain, title, url, ms) {
  if (!domain || ms < 1) return;
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
    state.connected = res.ok;
    state.lastError = res.ok ? "" : `HTTP ${res.status}`;
  } catch (err) {
    state.connected = false;
    state.lastError = String(err && err.message ? err.message : "offline");
  }
}

async function flush() {
  const now = Date.now();
  if (state.paused || !state.windowFocused || state.userIdle || !state.activeDomain || !state.activeSince) {
    state.activeSince = state.paused || !state.windowFocused || state.userIdle ? 0 : (state.activeDomain ? now : 0);
    await persistState();
    return;
  }
  const delta = now - state.activeSince;
  state.activeSince = now;
  if (delta >= 500) {
    await postUsage(state.activeDomain, state.activeTitle, state.activeUrl, delta);
  }
  await persistState();
}

async function refreshActiveTab() {
  await flush();
  if (state.paused || !state.windowFocused || state.userIdle) {
    state.activeSince = 0;
    await persistState();
    return;
  }
  try {
    const tabs = await api.tabs.query({ active: true, lastFocusedWindow: true });
    const tab = tabs && tabs[0];
    const domain = tab ? extractDomain(tab.url) : "";
    const url = domain && tab ? cleanUrl(tab.url) : "";
    const title = domain && tab ? cleanTitle(tab.title, domain, url) : "";
    const samePage = domain && domain === state.activeDomain && url === state.activeUrl;
    state.activeDomain = domain;
    state.activeUrl = url;
    state.activeTitle = title || (samePage ? state.activeTitle : "");
    state.activeSince = domain ? Date.now() : 0;
  } catch {
    state.activeDomain = "";
    state.activeTitle = "";
    state.activeUrl = "";
    state.activeSince = 0;
  }
  await persistState();
}

async function checkConnection() {
  try {
    const res = await fetch(PING_URL);
    state.connected = res.ok;
    state.lastError = res.ok ? "" : `HTTP ${res.status}`;
  } catch {
    state.connected = false;
    state.lastError = "offline";
  }
  await persistState();
}

serialized(async () => {
  await refreshActiveTab();
  await checkConnection();
});

api.tabs.onActivated.addListener(() => {
  serialized(() => refreshActiveTab());
});

api.tabs.onUpdated.addListener((_tabId, changeInfo, tab) => {
  if (!tab || !tab.active) return;
  if (changeInfo.url || changeInfo.status === "complete") {
    serialized(() => refreshActiveTab());
  } else if (changeInfo.title) {
    serialized(async () => {
      const dom = extractDomain(tab.url);
      const url = cleanUrl(tab.url);
      if (dom && dom === state.activeDomain) {
        const nextTitle = cleanTitle(changeInfo.title, dom, url);
        if (nextTitle && nextTitle !== state.activeTitle) {
          state.activeTitle = nextTitle;
          state.activeUrl = url;
          await postUsage(dom, nextTitle, url, 1);
          await persistState();
        }
      } else {
        await refreshActiveTab();
      }
    });
  }
});

api.windows.onFocusChanged.addListener((winId) => {
  serialized(async () => {
    state.windowFocused = winId !== api.windows.WINDOW_ID_NONE;
    await refreshActiveTab();
  });
});

if (api.idle && api.idle.setDetectionInterval) {
  api.idle.setDetectionInterval(60);
  api.idle.onStateChanged.addListener((idleState) => {
    serialized(async () => {
      state.userIdle = idleState !== "active";
      await refreshActiveTab();
    });
  });
}

if (api.alarms) {
  api.alarms.create("wolium-flush", { periodInMinutes: 0.25 });
  api.alarms.onAlarm.addListener((alarm) => {
    if (alarm.name === "wolium-flush") {
      serialized(async () => {
        if (!state.activeDomain) {
          await refreshActiveTab();
        } else {
          await flush();
        }
      });
    }
  });
}

api.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  if (!msg || typeof msg !== "object") return false;
  if (msg.type === "status") {
    serialized(async () => {
      await flush();
      if (!state.connected) await checkConnection();
      sendResponse({
        browser: detectBrowser(),
        domain: state.activeDomain,
        title: state.activeTitle,
        url: state.activeUrl,
        paused: state.paused,
        connected: state.connected,
        lastError: state.lastError,
      });
    });
    return true;
  }
  if (msg.type === "togglePause") {
    serialized(async () => {
      await flush();
      state.paused = !state.paused;
      await storageSet(api.storage.local, { paused: state.paused });
      await refreshActiveTab();
      sendResponse({ paused: state.paused });
    });
    return true;
  }
  return false;
});
