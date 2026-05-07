// Theme bootstrap — externalized from root.html.heex (audit M7).
//
// Loaded synchronously (NOT deferred) BEFORE the main app.js bundle so
// the document root carries `data-theme` before body paint, avoiding a
// brief light-theme flash on dark-themed pages. The script is its own
// esbuild entry (see `:theme_init` profile in config/config.exs) so
// the CSP `script-src 'self'` directive can stay strict — i.e. NOT
// `'unsafe-inline'` — without re-introducing the flash.
//
// Three responsibilities:
//   1. On first paint, derive `data-theme` from localStorage.
//   2. Mirror cross-tab theme changes via the `storage` event.
//   3. React to in-page `phx:set-theme` events emitted by the
//      LiveView theme picker (see lib/bank_web/components/layouts.ex).
(() => {
  const setTheme = (theme) => {
    if (theme === "system") {
      localStorage.removeItem("phx:theme");
      document.documentElement.removeAttribute("data-theme");
    } else {
      localStorage.setItem("phx:theme", theme);
      document.documentElement.setAttribute("data-theme", theme);
    }
  };
  if (!document.documentElement.hasAttribute("data-theme")) {
    setTheme(localStorage.getItem("phx:theme") || "system");
  }
  window.addEventListener("storage", (e) => e.key === "phx:theme" && setTheme(e.newValue || "system"));
  window.addEventListener("phx:set-theme", (e) => setTheme(e.target.dataset.phxTheme));
})();
