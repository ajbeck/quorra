// Quorra docs — theme toggle with persistence + cross-tab sync.
// Initial theme is set before paint to avoid FOUC; runs in <head> as a blocking
// script (deliberately not deferred). The CSS honors [data-theme="dark"]/[="light"]
// on <html>; when no attribute is set, the @media (prefers-color-scheme) fallback
// kicks in for JS-disabled environments.

(function () {
  const STORAGE_KEY = "quorra-docs-theme";
  const root = document.documentElement;

  // Resolve initial: stored preference > OS preference > "light".
  const stored = localStorage.getItem(STORAGE_KEY);
  const osDark = window.matchMedia("(prefers-color-scheme: dark)").matches;
  root.dataset.theme = stored ?? (osDark ? "dark" : "light");

  // Keep tabs in sync when the user toggles in another tab.
  window.addEventListener("storage", (event) => {
    if (event.key === STORAGE_KEY && event.newValue) {
      root.dataset.theme = event.newValue;
      syncButton();
    }
  });

  function syncButton() {
    const btn = document.querySelector(".theme-toggle");
    if (!btn) return;
    const isDark = root.dataset.theme === "dark";
    btn.setAttribute("aria-checked", String(isDark));
    btn.setAttribute("aria-label", isDark ? "Switch to light theme" : "Switch to dark theme");
  }

  function wire() {
    const btn = document.querySelector(".theme-toggle");
    if (!btn) return;
    syncButton();
    btn.addEventListener("click", () => {
      const next = root.dataset.theme === "dark" ? "light" : "dark";
      root.dataset.theme = next;
      localStorage.setItem(STORAGE_KEY, next);
      syncButton();
    });
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", wire);
  } else {
    wire();
  }
})();
