// Every .check on a page gets Works / Broken / Skipped and a note, kept in localStorage under walk:<page>:<id>.
const STATIONS = [
  ["dialogs.html", "A page's dialogs, under a hand"],
  ["menu.html", "The context menu and a ⌘-click"],
  ["windows.html", "Windows a page opens"],
  ["fullscreen.html", "Fullscreen and picture-in-picture"],
  ["location.html", "Where you are"],
  ["notifications.html", "Notifications"],
  ["capture.html", "Camera, microphone, screen"],
  ["history.html", "Back and forward, and a web archive"],
  ["agent.html", "An agent's hand: hover, drag, a dialog, a file"],
  ["extensions.html", "Extensions, and uBlock Origin Lite"],
  ["settings.html", "Switches nobody has pressed"],
  ["elsewhere.html", "On real sites"],
];
const page = location.pathname.split("/").pop() || "index.html";
const key = (p, id) => `walk:${p}:${id}`;
const read = (p, id) => { try { return JSON.parse(localStorage.getItem(key(p, id))) || {}; } catch { return {}; } };
const write = (p, id, value) => { try { localStorage.setItem(key(p, id), JSON.stringify(value)); } catch {} };
function log(id, ...parts) {
  const out = document.getElementById(id);
  const line = parts.map(x => typeof x === "string" ? x : JSON.stringify(x)).join(" ");
  out.textContent += (out.textContent ? "\n" : "") + new Date().toTimeString().slice(0, 8) + "  " + line;
}
function verdicts() {
  for (const check of document.querySelectorAll(".check[id]")) {
    const saved = read(page, check.id);
    const bar = document.createElement("div");
    bar.className = "verdict";
    for (const [v, label] of [["ok", "Works"], ["bad", "Broken"], ["skip", "Skipped"]]) {
      const b = document.createElement("button");
      b.textContent = label; b.dataset.v = v; b.setAttribute("aria-pressed", saved.v === v);
      b.onclick = () => {
        const now = read(page, check.id);
        now.v = now.v === v ? undefined : v; now.title = check.querySelector("h2").textContent; write(page, check.id, now);
        bar.querySelectorAll("button").forEach(x => x.setAttribute("aria-pressed", now.v === x.dataset.v));
      };
      bar.append(b);
    }
    const note = document.createElement("input");
    note.placeholder = "what you saw"; note.value = saved.note || "";
    note.oninput = () => { const now = read(page, check.id); now.note = note.value; now.title = check.querySelector("h2").textContent; write(page, check.id, now); };
    bar.append(note);
    check.append(bar);
  }
}
function header() {
  if (page === "index.html") return;
  const i = STATIONS.findIndex(s => s[0] === page);
  const nav = document.createElement("nav");
  const next = STATIONS[i + 1];
  nav.innerHTML = `<a href="index.html">← all stations</a>` + (next ? ` · next: <a href="${next[0]}">${next[1]}</a>` : "");
  document.body.prepend(nav);
}
function report() {
  const lines = [];
  for (const [file, title] of STATIONS) {
    const rows = [];
    for (let i = 0; i < localStorage.length; i++) {
      const k = localStorage.key(i);
      if (!k.startsWith(`walk:${file}:`)) continue;
      const value = read(file, k.split(":").slice(2).join(":"));
      if (value.v || value.note) rows.push(`- ${({ ok: "WORKS", bad: "BROKEN", skip: "skipped" })[value.v] || "no verdict"} — ${value.title || k}${value.note ? ": " + value.note : ""}`);
    }
    if (rows.length) lines.push(`## ${title}`, ...rows.sort(), "");
  }
  return `Walk of ${new Date().toISOString().slice(0, 10)}, ${navigator.userAgent.match(/Version\/[\d.]+/)?.[0] || "Savoia"}\n\n` + (lines.join("\n") || "nothing answered yet");
}
addEventListener("DOMContentLoaded", () => { header(); verdicts(); });
