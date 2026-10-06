/* =====================================================================
   SITE MENU  v2   -  the three-line ("hamburger") button on every page,
                      and (new in v2) the light / dark button beside it

   THE ONE LIST OF PAGES IS HERE.
   To add a new page to the menu on EVERY page, add one line to PAGES.
   Rule for this project: every new page gets a line here on the day it
   is created, so nothing is ever unreachable while the layout is still
   being decided.

   How a page uses it:
     <div id="menu"></div>                      where the button should sit
     <script src="menu.js"></script>
     SiteMenu.draw("en");                       or "ms"
     SiteMenu.draw("en", [{ id: "logout", label: "Sign out", action: fn }]);   extra buttons under the links

   LIGHT / DARK
     Which one the page starts in is decided by the small script at the top of each page's <head>
     (it must run before anything is drawn). This file only draws the sun / moon button and remembers
     the choice on the device. If this file is missing, the page still picks light or dark by itself.
     The button sits just before the menu button, unless the page has <div id="theme"></div>: then it goes there.
   ===================================================================== */
(function () {
  const PAGES = [
    { href: "./",           en: "Staff attendance",        ms: "Kehadiran staf" },
    { href: "admin.html",   en: "Admin",                   ms: "Pentadbir" },
    { href: "display.html", en: "QR display (big screen)", ms: "Paparan QR (skrin besar)" }
  ];
  const WORDS = { en: { menu: "Menu", toDark: "Switch to dark", toLight: "Switch to light" },
                  ms: { menu: "Menu", toDark: "Tukar ke mod gelap", toLight: "Tukar ke mod cerah" } };

  /* The look. It uses the colour names every page already defines. */
  const style = document.createElement("style");
  style.textContent = `
    .menu{flex:none; position:relative; display:flex; gap:8px}
    .menu-btn{width:44px; height:40px; padding:0; display:grid; place-items:center; cursor:pointer;
      border:1.5px solid var(--line); border-radius:10px; background:var(--card); color:var(--ink)}
    .menu-btn:hover{border-color:var(--mute)}
    .menu-btn svg{width:20px; height:20px; fill:none; stroke:currentColor; stroke-width:2; stroke-linecap:round; stroke-linejoin:round}
    .menu-btn:focus-visible,.menu-list :is(a,button):focus-visible{outline:3px solid var(--brand); outline-offset:2px}
    .menu-list{position:fixed; inset:auto; margin:0; padding:6px; min-width:230px; max-width:calc(100vw - 24px);
      border:1.5px solid var(--line); border-radius:12px; background:var(--card); color:var(--ink);
      box-shadow:0 1px 2px rgb(0 0 0 / .12), 0 10px 18px -8px rgb(0 0 0 / .35)}
    .menu-list:not([popover]){z-index:20}
    .menu-list :is(a,button){display:flex; align-items:center; width:100%; min-height:44px; padding:.45rem .7rem;
      font:inherit; font-weight:600; text-align:left; text-decoration:none; color:var(--ink);
      border:0; border-radius:8px; background:transparent; cursor:pointer}
    .menu-list :is(a,button):hover{background:var(--bg)}
    .menu-list a[aria-current="page"]{color:var(--brand)}
    .menu-list a[aria-current="page"]::after{content:""; width:8px; height:8px; margin-left:auto; border-radius:50%; background:var(--brand)}
    .menu-list hr{border:0; border-top:1px solid var(--line); margin:6px 4px}
    /* The sun / moon button: both drawings sit on top of each other, and only one shows. */
    .theme-btn svg{overflow:visible}
    .theme-btn :is(.sun,.moon){transform-box:view-box; transform-origin:center}
    :root[data-theme="dark"] .theme-btn .sun, :root:not([data-theme="dark"]) .theme-btn .moon{opacity:0}
    @media (prefers-reduced-motion:no-preference){
      .theme-btn :is(.sun,.moon){transition:opacity .25s ease, transform .55s cubic-bezier(.16,1,.3,1)}
      :root[data-theme="dark"] .theme-btn .sun{transform:rotate(90deg) scale(.4)}
      :root:not([data-theme="dark"]) .theme-btn .moon{transform:rotate(-90deg) scale(.4)}
    }
    /* The change spreads over the page as a circle that opens from the button (see setTheme). */
    ::view-transition-old(root),::view-transition-new(root){animation:none; mix-blend-mode:normal}
  `;
  document.head.append(style);

  let oldBrowserReady = false;

  /* ----- light / dark ----- */
  const root = document.documentElement;
  const isDark = () => root.dataset.theme === "dark";
  const autoTheme = () => typeof window.themeAuto === "function" ? window.themeAuto() : "light";
  const nameThemeButton = (button, words) => {
    const label = isDark() ? words.toLight : words.toDark;         // the label says what a press will do
    button.setAttribute("aria-label", label); button.title = label;
    button.setAttribute("aria-pressed", String(isDark()));
  };
  function setTheme(next, button, words) {
    const apply = () => {
      root.dataset.theme = next;
      // Remember the choice on this device - unless it is exactly what the page would pick by itself right now.
      // Then nothing is kept, and the page goes back to choosing by the time of day.
      try { if (next === autoTheme()) localStorage.removeItem("theme"); else localStorage.setItem("theme", next); } catch (e) { /* storage blocked: it lasts until the page is closed */ }
      nameThemeButton(button, words);
    };
    const calm = window.matchMedia && matchMedia("(prefers-reduced-motion: reduce)").matches;
    if (!document.startViewTransition || calm) { apply(); return; }
    // Newer browsers: the new colours open as a circle from the middle of the button to the far corner.
    const box = button.getBoundingClientRect(), x = box.left + box.width / 2, y = box.top + box.height / 2;
    const far = Math.hypot(Math.max(x, window.innerWidth - x), Math.max(y, window.innerHeight - y));
    try {
      document.startViewTransition(apply).ready.then(() => root.animate(
        { clipPath: ["circle(0px at " + x + "px " + y + "px)", "circle(" + far + "px at " + x + "px " + y + "px)"] },
        { duration: 600, easing: "cubic-bezier(.16,1,.3,1)", pseudoElement: "::view-transition-new(root)" })).catch(() => {});
    } catch (e) { apply(); }
  }

  const samePage = href => {
    const clean = path => path.replace(/index\.html$/, "");
    return clean(new URL(href, location.href).pathname) === clean(location.pathname);
  };

  function draw(lang, extras) {
    const holder = document.getElementById("menu");
    if (!holder) return;
    const words = WORDS[lang] || WORDS.en, canFloat = "popover" in HTMLElement.prototype;
    const wasOpen = canFloat && !!document.querySelector("#menuList:popover-open");
    holder.className = "menu";

    const button = document.createElement("button");
    button.type = "button"; button.id = "menuBtn"; button.className = "menu-btn";
    button.setAttribute("aria-label", words.menu); button.setAttribute("aria-haspopup", "true");
    button.innerHTML = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 7h16M4 12h16M4 17h16"/></svg>';

    // The light / dark button. One drawing style for both: a sun with eight rays, and a crescent moon.
    const theme = document.createElement("button");
    theme.type = "button"; theme.id = "themeBtn"; theme.className = "menu-btn theme-btn";
    theme.innerHTML = '<svg viewBox="0 0 24 24" aria-hidden="true">'
      + '<g class="sun"><circle cx="12" cy="12" r="4"/><path d="M12 2.5v2M12 19.5v2M2.5 12h2M19.5 12h2M5.3 5.3l1.4 1.4M17.3 17.3l1.4 1.4M5.3 18.7l1.4-1.4M17.3 6.7l1.4-1.4"/></g>'
      + '<path class="moon" d="M20.5 13.2A8.5 8.5 0 1 1 10.8 3.5a7 7 0 0 0 9.7 9.7z"/></svg>';
    nameThemeButton(theme, words);
    theme.addEventListener("click", () => setTheme(isDark() ? "light" : "dark", theme, words));

    const list = document.createElement("div");
    list.id = "menuList"; list.className = "menu-list";
    for (const page of PAGES) {
      const link = document.createElement("a");
      link.href = page.href; link.textContent = page[lang] || page.en;
      if (samePage(page.href)) link.setAttribute("aria-current", "page");
      list.append(link);
    }
    if (extras && extras.length) {
      list.append(document.createElement("hr"));
      for (const extra of extras) {
        const item = document.createElement("button");
        item.type = "button"; item.textContent = extra.label; if (extra.id) item.id = extra.id;
        item.addEventListener("click", () => { close(); extra.action(); });
        list.append(item);
      }
    }

    /* Put the list just under the button, lined up with its right edge. */
    const place = () => {
      const box = button.getBoundingClientRect();
      list.style.top = Math.round(box.bottom + 6) + "px";
      list.style.right = Math.max(12, Math.round(window.innerWidth - box.right)) + "px";
    };
    const close = () => { if (canFloat) { if (list.matches(":popover-open")) list.hidePopover(); } else list.hidden = true; };

    if (canFloat) {
      // Modern browsers: the browser itself closes it on Escape or a click elsewhere.
      list.popover = "auto"; button.popoverTargetElement = list;
      list.addEventListener("beforetoggle", event => { if (event.newState === "open") place(); });
    } else {
      // Older browsers: open and close it by hand.
      list.hidden = true;
      button.addEventListener("click", event => { event.stopPropagation(); place(); list.hidden = !list.hidden; });
      if (!oldBrowserReady) {
        oldBrowserReady = true;
        const shut = () => { const open = document.getElementById("menuList"); if (open) open.hidden = true; };
        document.addEventListener("click", event => { const open = document.getElementById("menuList"); if (open && !open.contains(event.target)) shut(); });
        document.addEventListener("keydown", event => { if (event.key === "Escape") shut(); });
      }
    }
    // Where the light / dark button goes: into <div id="theme"> if the page has one (the staff page, whose
    // top row is already full on a phone), otherwise just before the menu button.
    const slot = document.getElementById("theme");
    if (slot) { slot.className = "menu"; slot.replaceChildren(theme); holder.replaceChildren(button, list); }
    else holder.replaceChildren(theme, button, list);
    if (wasOpen) { place(); list.showPopover(); }
  }

  window.SiteMenu = { draw };
})();