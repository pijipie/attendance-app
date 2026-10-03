/* =====================================================================
   SITE MENU  v1   -  the three-line ("hamburger") button on every page

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
   ===================================================================== */
(function () {
  const PAGES = [
    { href: "./",           en: "Staff attendance",        ms: "Kehadiran staf" },
    { href: "admin.html",   en: "Admin",                   ms: "Pentadbir" },
    { href: "display.html", en: "QR display (big screen)", ms: "Paparan QR (skrin besar)" }
  ];
  const WORDS = { en: { menu: "Menu" }, ms: { menu: "Menu" } };

  /* The look. It uses the colour names every page already defines. */
  const style = document.createElement("style");
  style.textContent = `
    .menu{flex:none; position:relative}
    .menu-btn{width:44px; height:40px; padding:0; display:grid; place-items:center; cursor:pointer;
      border:1.5px solid var(--line); border-radius:10px; background:var(--card); color:var(--ink)}
    .menu-btn:hover{border-color:var(--mute)}
    .menu-btn svg{width:20px; height:20px; fill:none; stroke:currentColor; stroke-width:2; stroke-linecap:round}
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
  `;
  document.head.append(style);

  let oldBrowserReady = false;

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
    holder.replaceChildren(button, list);
    if (wasOpen) { place(); list.showPopover(); }
  }

  window.SiteMenu = { draw };
})();