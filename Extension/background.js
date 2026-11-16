// Ponte entre as abas do navegador e o DeadNoise (app do Mac).
//
// O navegador toca o áudio de todas as abas num único processo, então o macOS não consegue separar
// uma aba da outra. A extensão faz isso por dentro: manda ao app a lista de abas que tocam som e
// recebe dele o volume (0–100%) e o mudo de cada uma.
//
// Conversa por native messaging: o navegador abre o "host" do DeadNoise, que liga esta porta ao
// socket local do app. Nada sai do Mac.

const HOST = "com.wellingtonmota.deadnoise";

let port = null;
let retry = 2000;
let sendTimer = null;
const favicons = new Map(); // origem -> data URL

// MARK: Estado (sobrevive ao service worker ser descarregado)

async function gains() {
  return (await chrome.storage.session.get("gains")).gains ?? {};
}

async function setGainState(tabId, gain) {
  const all = await gains();
  if (gain >= 0.999) delete all[tabId]; else all[tabId] = gain;
  await chrome.storage.session.set({ gains: all });
}

async function applyGain(tabId, gain) {
  try {
    await chrome.scripting.executeScript({
      target: { tabId, allFrames: true },
      world: "MAIN",
      func: (g) => window.__deadnoiseSetGain?.(g),
      args: [gain],
    });
  } catch {
    // Páginas internas (chrome://, loja de extensões) não aceitam scripts.
  }
}

// MARK: Conexão com o app

function connect() {
  if (port) return;
  try {
    port = chrome.runtime.connectNative(HOST);
  } catch {
    port = null;
    return scheduleReconnect();
  }
  port.onMessage.addListener(onAppMessage);
  port.onDisconnect.addListener(() => {
    void chrome.runtime.lastError; // app fechado ou host não instalado
    port = null;
    scheduleReconnect();
  });
  const brand = navigator.userAgentData?.brands?.find((b) => !/Chromium|Not/i.test(b.brand))?.brand;
  port.postMessage({ type: "hello", browser: brand ?? "Chromium", version: chrome.runtime.getManifest().version });
  retry = 2000;
  scheduleSend();
}

function scheduleReconnect() {
  setTimeout(connect, retry);
  retry = Math.min(retry * 2, 30000);
}

async function onAppMessage(msg) {
  const tabId = Number(msg?.tabId);
  if (!Number.isInteger(tabId)) return;
  try {
    switch (msg.type) {
      case "gain": {
        const g = Math.min(1, Math.max(0, Number(msg.gain)));
        if (Number.isNaN(g)) return;
        await setGainState(tabId, g);
        await applyGain(tabId, g);
        break;
      }
      case "mute":
        await chrome.tabs.update(tabId, { muted: !!msg.muted });
        break;
      case "focus": {
        const tab = await chrome.tabs.update(tabId, { active: true });
        await chrome.windows.update(tab.windowId, { focused: true });
        break;
      }
    }
  } catch {
    // A aba pode ter fechado nesse meio-tempo.
  }
  scheduleSend();
}

// MARK: Lista de abas

async function favicon(url) {
  let origin;
  try { origin = new URL(url).origin; } catch { return null; }
  if (favicons.has(origin)) return favicons.get(origin);
  try {
    const u = new URL(chrome.runtime.getURL("/_favicon/"));
    u.searchParams.set("pageUrl", url);
    u.searchParams.set("size", "32");
    const bytes = new Uint8Array(await (await fetch(u)).arrayBuffer());
    let bin = "";
    for (const b of bytes) bin += String.fromCharCode(b);
    const data = "data:image/png;base64," + btoa(bin);
    favicons.set(origin, data);
    return data;
  } catch {
    return null;
  }
}

function scheduleSend() {
  clearTimeout(sendTimer);
  sendTimer = setTimeout(sendTabs, 150);
}

async function sendTabs() {
  if (!port) return;
  const all = await gains();
  const tabs = await chrome.tabs.query({});
  const list = [];
  for (const t of tabs) {
    const gain = all[t.id] ?? 1;
    const muted = !!t.mutedInfo?.muted;
    if (!t.audible && gain === 1 && !muted) continue;
    list.push({
      id: t.id,
      title: t.title || t.url || "",
      host: (() => { try { return new URL(t.url).hostname; } catch { return ""; } })(),
      favicon: t.url ? await favicon(t.url) : null,
      audible: !!t.audible,
      muted,
      gain,
    });
  }
  // Volumes de abas que já fecharam.
  const open = new Set(tabs.map((t) => String(t.id)));
  if (Object.keys(all).some((id) => !open.has(id))) {
    for (const id of Object.keys(all)) if (!open.has(id)) delete all[id];
    await chrome.storage.session.set({ gains: all });
  }
  port?.postMessage({ type: "tabs", tabs: list });
}

// MARK: Eventos

chrome.tabs.onUpdated.addListener(async (tabId, change) => {
  connect();
  // Página nova ou iframe que começou a tocar: reaplica o volume escolhido.
  if (change.status === "complete" || change.audible === true) {
    const g = (await gains())[tabId];
    if (g !== undefined) await applyGain(tabId, g);
  }
  if ("audible" in change || "mutedInfo" in change || "title" in change || "favIconUrl" in change || "url" in change) {
    scheduleSend();
  }
});
chrome.tabs.onRemoved.addListener(() => { connect(); scheduleSend(); });
chrome.runtime.onStartup.addListener(connect);
chrome.runtime.onInstalled.addListener(connect);
chrome.alarms.create("deadnoise-reconnect", { periodInMinutes: 1 });
chrome.alarms.onAlarm.addListener(connect);

connect();
