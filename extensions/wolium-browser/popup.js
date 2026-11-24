const api = globalThis.browser ?? globalThis.chrome;
const TOP_URL = "http://127.0.0.1:9095/v1/browser/top?days=1&limit=7";

const UI_LANG = (() => {
  try {
    const l = (api.i18n && api.i18n.getUILanguage ? api.i18n.getUILanguage() : navigator.language || "en").toLowerCase();
    return l.startsWith("ru") ? "ru" : "en";
  } catch {
    return "en";
  }
})();

const STR = UI_LANG === "ru"
  ? {
      checking: "Проверка...",
      currentTab: "Текущая вкладка",
      internalTab: "Системная вкладка браузера — откройте любой сайт для учёта",
      topSites: "Топ сайтов за сегодня",
      noSites: "Сайты ещё не записаны",
      enableApi: "Включите Локальный API в настройках Wolium",
      paused: "На паузе",
      connected: (b) => `Активно (${b})`,
      offline: "Офлайн",
      pause: "Пауза",
      resume: "Продолжить",
      tip: "Совет: закрепите иконку Wolium на панели браузера — мини-меню доступно на любом сайте для быстрой проверки и паузы.",
      unitS: "с",
      unitM: "м",
      unitH: "ч",
    }
  : {
      checking: "Checking...",
      currentTab: "Current tab",
      internalTab: "Internal browser page — open any website to track",
      topSites: "Top sites today",
      noSites: "No sites recorded yet",
      enableApi: "Enable Local API in Wolium Settings",
      paused: "Paused",
      connected: (b) => `Connected (${b})`,
      offline: "Offline",
      pause: "Pause",
      resume: "Resume",
      tip: "Tip: pin the Wolium icon to your toolbar to open this mini menu from any website for quick stats and pause control.",
      unitS: "s",
      unitM: "m",
      unitH: "h",
    };

function fmtMs(ms) {
  const s = Math.floor(ms / 1000);
  if (s < 60) return `${s}${STR.unitS}`;
  const m = Math.floor(s / 60);
  if (m < 60) return `${m}${STR.unitM} ${s % 60}${STR.unitS}`;
  const h = Math.floor(m / 60);
  return `${h}${STR.unitH} ${m % 60}${STR.unitM}`;
}

function cleanDisplay(title, domain) {
  const t = (title || "").trim();
  if (!t) return domain || "";
  const lt = t.toLowerCase();
  const ld = (domain || "").toLowerCase();
  const bare = ld.startsWith("www.") ? ld.slice(4) : ld;
  if (/^(https?|file|about|chrome|edge|opera|brave|vivaldi|moz-extension):/i.test(lt)) return domain || t;
  if (ld && (lt === ld || lt === `www.${ld}` || lt === bare || lt.startsWith(`${ld}/`) || lt.startsWith(`www.${ld}/`) || lt.startsWith(`${bare}/`))) {
    return domain || t;
  }
  if (!lt.includes(" ") && /^[a-z0-9-]+(\.[a-z0-9-]+)+(:\d+)?(\/.*)?$/i.test(lt)) return domain || t;
  return t;
}

function sendMsg(msg) {
  return new Promise((resolve) => {
    api.runtime.sendMessage(msg, (res) => resolve(res || {}));
  });
}

async function loadTop() {
  const box = document.getElementById("topList");
  try {
    const res = await fetch(TOP_URL);
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const data = await res.json();
    const list = Array.isArray(data.domains) ? data.domains : [];
    if (!list.length) {
      box.innerHTML = "";
      const span = document.createElement("span");
      span.className = "muted";
      span.textContent = STR.noSites;
      box.appendChild(span);
      return;
    }
    box.innerHTML = "";
    for (const item of list) {
      const row = document.createElement("div");
      row.className = "item";
      const name = document.createElement("span");
      name.className = "item-name";
      name.textContent = cleanDisplay(item.title, item.domain);
      if (item.domain) name.title = item.domain;
      const time = document.createElement("span");
      time.className = "item-time";
      time.textContent = fmtMs(Number(item.ms) || 0);
      row.appendChild(name);
      row.appendChild(time);
      box.appendChild(row);
    }
  } catch {
    box.innerHTML = "";
    const span = document.createElement("span");
    span.className = "muted";
    span.textContent = STR.enableApi;
    box.appendChild(span);
  }
}

async function refresh() {
  document.documentElement.lang = UI_LANG;
  const topTitle = document.getElementById("topTitle");
  if (topTitle) topTitle.textContent = STR.topSites;
  const tabLabel = document.getElementById("tabLabel");
  if (tabLabel) tabLabel.textContent = STR.currentTab;
  const tipEl = document.getElementById("tipText");
  if (tipEl) tipEl.textContent = STR.tip;

  const st = await sendMsg({ type: "status" });
  const dot = document.getElementById("dot");
  const badge = document.getElementById("statusBadge");
  const domainEl = document.getElementById("activeDomain");
  const hostEl = document.getElementById("activeHost");
  const pauseBtn = document.getElementById("pauseBtn");

  dot.className = st.connected && !st.paused ? "dot ok" : "dot";
  badge.className = st.connected && !st.paused ? "badge ok" : "badge";
  if (st.paused) {
    badge.textContent = STR.paused;
  } else if (st.connected) {
    badge.textContent = STR.connected(st.browser || "browser");
  } else {
    badge.textContent = STR.offline;
  }

  if (st.domain) {
    const label = cleanDisplay(st.title, st.domain);
    domainEl.textContent = label;
    domainEl.className = "domain";
    hostEl.textContent = label !== st.domain ? st.domain : "";
  } else {
    domainEl.textContent = STR.internalTab;
    domainEl.className = "muted";
    hostEl.textContent = "";
  }
  pauseBtn.textContent = st.paused ? STR.resume : STR.pause;
  await loadTop();
}

document.getElementById("pauseBtn").addEventListener("click", async () => {
  await sendMsg({ type: "togglePause" });
  await refresh();
});

refresh();
