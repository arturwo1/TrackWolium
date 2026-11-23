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
      checking: "Проверка Wolium...",
      topSites: "Топ сайтов за сегодня",
      noSites: "Сайты ещё не записаны",
      enableApi: "Включите Локальный API в настройках Wolium",
      paused: "Отслеживание на паузе",
      connected: (b) => `Подключено (${b})`,
      offline: "Локальный API Wolium не в сети (127.0.0.1:9095)",
      pause: "Пауза",
      resume: "Продолжить",
      unitS: "с",
      unitM: "м",
      unitH: "ч",
    }
  : {
      checking: "Checking Wolium...",
      topSites: "Top sites today",
      noSites: "No sites recorded yet",
      enableApi: "Enable Local API in Wolium Settings",
      paused: "Extension tracking paused",
      connected: (b) => `Connected (${b})`,
      offline: "Wolium Local API offline (127.0.0.1:9095)",
      pause: "Pause",
      resume: "Resume",
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
  const statusText = document.getElementById("statusText");
  if (statusText && !statusText.dataset.init) {
    statusText.textContent = STR.checking;
    statusText.dataset.init = "1";
  }

  const st = await sendMsg({ type: "status" });
  const dot = document.getElementById("dot");
  const domainEl = document.getElementById("activeDomain");
  const pauseBtn = document.getElementById("pauseBtn");

  dot.className = st.connected ? "dot ok" : "dot";
  if (st.paused) {
    statusText.textContent = STR.paused;
  } else if (st.connected) {
    statusText.textContent = STR.connected(st.browser || "browser");
  } else {
    statusText.textContent = STR.offline;
  }
  domainEl.textContent = st.domain ? cleanDisplay(st.title, st.domain) : "—";
  pauseBtn.textContent = st.paused ? STR.resume : STR.pause;
  await loadTop();
}

document.getElementById("pauseBtn").addEventListener("click", async () => {
  await sendMsg({ type: "togglePause" });
  await refresh();
});

refresh();
