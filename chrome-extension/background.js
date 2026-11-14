/* PasClaw for Chrome -- service worker.
   Opens the side panel from the toolbar button, adds the context-menu
   entries, keeps the gateway Origin rule in step with the settings and
   shows gateway health on the toolbar badge. */

import { getSettings, onSettingsChanged, syncOriginRule, checkHealth, extractPageInTab } from "./lib/config.js";

const MENU_SELECTION = "pasclaw-ask-selection";
const MENU_PAGE = "pasclaw-ask-page";
const MENU_LINK = "pasclaw-ask-link";
const HEALTH_ALARM = "pasclaw-health";

async function setup() {
  await chrome.sidePanel.setPanelBehavior({ openPanelOnActionClick: true }).catch(() => {});
  await chrome.contextMenus.removeAll();
  chrome.contextMenus.create({ id: MENU_SELECTION, title: "Ask PasClaw about \"%s\"", contexts: ["selection"] });
  chrome.contextMenus.create({ id: MENU_PAGE, title: "Ask PasClaw about this page", contexts: ["page"] });
  chrome.contextMenus.create({ id: MENU_LINK, title: "Ask PasClaw about this link", contexts: ["link"] });
  await chrome.alarms.create(HEALTH_ALARM, { periodInMinutes: 1 });
  await syncOriginRule().catch((e) => console.warn("origin rule:", e));
  await refreshBadge();
}

chrome.runtime.onInstalled.addListener(setup);
chrome.runtime.onStartup.addListener(setup);

onSettingsChanged(async (s) => {
  await syncOriginRule(s).catch((e) => console.warn("origin rule:", e));
  await refreshBadge(s);
});

chrome.alarms.onAlarm.addListener((a) => {
  if (a.name === HEALTH_ALARM) refreshBadge();
});

async function refreshBadge(settings) {
  const h = await checkHealth(settings || (await getSettings()));
  await chrome.action.setBadgeBackgroundColor({ color: h.ok ? "#3df281" : "#ff4d6d" });
  await chrome.action.setBadgeText({ text: h.ok ? "" : "!" });
  await chrome.action.setTitle({ title: h.ok ? "Open PasClaw" : `PasClaw gateway ${h.error}` });
}

/* A context-menu click is a user gesture, and sidePanel.open must be called
   inside it -- before any await -- or Chrome refuses. The prompt is handed
   to the panel through storage.session, which the panel watches. */
chrome.contextMenus.onClicked.addListener((info, tab) => {
  if (!tab || tab.id === undefined) return;
  chrome.sidePanel.open({ tabId: tab.id }).catch((e) => console.warn("sidePanel.open:", e));
  stagePrompt(info, tab).catch((e) => console.warn("stage prompt:", e));
});

async function stagePrompt(info, tab) {
  const s = await getSettings();
  let page = { title: tab.title || "", url: tab.url || "", selection: "", text: "", description: "", truncated: false };
  if (info.menuItemId !== MENU_LINK) {
    try {
      /* The context-menu click granted activeTab for this tab. */
      const [res] = await chrome.scripting.executeScript({
        target: { tabId: tab.id },
        func: extractPageInTab,
        args: [s.pageCharLimit],
      });
      if (res && res.result) page = res.result;
    } catch {
      /* chrome:// pages, the Web Store and the like: fall back to the title. */
    }
  }
  let staged;
  if (info.menuItemId === MENU_SELECTION) {
    page.selection = (info.selectionText || page.selection || "").slice(0, s.pageCharLimit);
    page.text = "";
    staged = { draft: "Explain this:", page, autoSend: false };
  } else if (info.menuItemId === MENU_LINK) {
    staged = {
      draft: `Fetch ${info.linkUrl} and summarize it.`,
      page: { title: tab.title || "", url: tab.url || "", selection: "", text: "", description: "", truncated: false },
      autoSend: false,
    };
  } else {
    staged = { draft: "Summarize this page.", page, autoSend: false };
  }
  staged.at = Date.now();
  await chrome.storage.session.set({ staged });
}
