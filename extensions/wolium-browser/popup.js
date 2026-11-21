const api = globalThis.browser ?? globalThis.chrome;
const TOP_URL = "http://127.0.0.1:9095/v1/browser/top?days=1&limit=7";

function fmtMs(ms) {
  const s = Math.floor(ms / 1000);
  if (s < 60) return `${s}s`;
  const m = Math.floor(s / 60);
  if (m < 60) return `${m}m ${s % 60}s`;
  const h = Math.floor(m / 60);
  return `${h}h ${m % 60}m`;
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
      box.innerHTML = '<span class="muted">No sites recorded yet</span>';
      return;
    }
    box.innerHTML = "";
    for (const item of list) {
      const row = document.createElement("div");
      row.className = "item";
      const name = document.createElement("span");
      name.className = "item-name";
      name.textContent = item.title || item.domain;
      if (item.domain) name.title = item.domain;
      const time = document.createElement("span");
      time.className = "item-time";
      time.textContent = fmtMs(Number(item.ms) || 0);
      row.appendChild(name);
      row.appendChild(time);
      box.appendChild(row);
    }
  } catch {
    box.innerHTML = '<span class="muted">Enable Local API in Wolium Settings</span>';
  }
}

async function refresh() {
  const st = await sendMsg({ type: "status" });
  const dot = document.getElementById("dot");
  const statusText = document.getElementById("statusText");
  const domainEl = document.getElementById("activeDomain");
  const pauseBtn = document.getElementById("pauseBtn");

  dot.className = st.connected ? "dot ok" : "dot";
  if (st.paused) {
    statusText.textContent = "Extension tracking paused";
  } else if (st.connected) {
    statusText.textContent = `Connected (${st.browser || "browser"})`;
  } else {
    statusText.textContent = "Wolium Local API offline (127.0.0.1:9095)";
  }
  domainEl.textContent = st.title || st.domain || "—";
  pauseBtn.textContent = st.paused ? "Resume" : "Pause";
  await loadTop();
}

document.getElementById("pauseBtn").addEventListener("click", async () => {
  await sendMsg({ type: "togglePause" });
  await refresh();
});

refresh();
