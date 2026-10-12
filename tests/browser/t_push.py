import json, sys, time, threading, http.server, socketserver, functools, datetime, re
from playwright.sync_api import sync_playwright
# Version 0.9: Remind Me on the staff page (2.13), sw.js, and the count in the admin Settings (3.11).
# The browser's push parts and Supabase are answered by this test. Run: python3 tests/browser/t_push.py .
ROOT = sys.argv[1]; PORT = 8773
class Q(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a): pass
socketserver.TCPServer.allow_reuse_address = True
srv = socketserver.TCPServer(("127.0.0.1", PORT), functools.partial(Q, directory=ROOT))
threading.Thread(target=srv.serve_forever, daemon=True).start()
TEST_KEY = "BEl62iUYgUivxIkv69yViEuiBIa-Ib9-SkvMeAtA3LFgDzkrxZJjSgSnfckjBJuBkr3qBUYIHBQFLXYp5Nksh8U"   # a sample public key, 65 bytes
INDEX = open(ROOT + "/index.html", encoding="utf-8").read()
assert 'const VAPID_PUBLIC = "' in INDEX

FAKE = """
(() => {
  const P = window.__push = { subs: null, perm: "granted", regFail: false, asked: 0, subscribed: 0, unsubscribed: 0, keyLength: 0 };
  const sub = () => ({ endpoint: "https://push.example.test/send/abc",
    toJSON() { return { endpoint: this.endpoint, keys: { p256dh: "BPkey123", auth: "authkey456" } }; },
    unsubscribe() { P.unsubscribed++; P.subs = null; return Promise.resolve(true); } });
  const manager = { getSubscription: () => Promise.resolve(P.subs),
                    subscribe: o => { P.subscribed++; P.keyLength = o.applicationServerKey.length; P.subs = sub(); return Promise.resolve(P.subs); } };
  if (window.__noPush) { delete window.PushManager; return; }
  Object.defineProperty(navigator, "serviceWorker", { configurable: true, value: {
    register: url => { P.registered = url; return P.regFail ? Promise.reject(new Error("no sw.js")) : Promise.resolve({ pushManager: manager }); } } });
  window.PushManager = window.PushManager || function () {};
  window.Notification = { permission: "default", requestPermission: () => { P.asked++; return Promise.resolve(P.perm); } };
})();
"""
EVENTS = [{"event_code": "WEB1", "name": "Online Briefing", "require_qr": False, "open_now": True, "require_location": False, "audience": "all", "allow_exit": False}]
results = []
def check(name, cond, extra=""):
    results.append((name, bool(cond))); print(("PASS " if cond else "FAIL ") + name + (("  -> " + str(extra)) if (extra and not cond) else ""))

def staff_page(browser, key=TEST_KEY, push_status=200, no_push=False, reg_fail=False, perm="granted", ua=None, lang=None):
    ctx = browser.new_context(viewport={"width": 390, "height": 800}, **({"user_agent": ua} if ua else {}))
    page = ctx.new_page()
    calls = {"subscribe": [], "unsubscribe": [], "link": [], "check_in": []}
    state = {"reply": {"ok": True, "name": "Test One", "event": "Online Briefing", "distance_m": None}, "link_delay": 0, "held": []}
    def handle(route):
        url = route.request.url; body = route.request.post_data_json if route.request.post_data else {}
        if url.endswith("/rpc/list_events"): return route.fulfill(json=EVENTS)
        if url.endswith("/rpc/event_counter"): return route.fulfill(json={"window_label": "Pagi", "window_state": "open", "present": 4, "total": 70})
        if url.endswith("/rpc/check_in"): calls["check_in"].append(body); return route.fulfill(json=state["reply"])
        if url.endswith("/rpc/push_subscribe"): calls["subscribe"].append(body); return route.fulfill(status=push_status, json={"ok": True} if push_status == 200 else {"code": "PGRST202"})
        if url.endswith("/rpc/push_unsubscribe"): calls["unsubscribe"].append(body); return route.fulfill(json={"ok": True})
        if url.endswith("/rpc/push_link"):
            calls["link"].append(body)
            if state["link_delay"]: state["held"].append(route); return    # answered later: a slow link must not hold up the page
            return route.fulfill(json={"ok": True})
        return route.fulfill(status=404, json={})
    page.route("https://xtrgefkopnqgektrllra.supabase.co/**", handle)
    # The repository's page has no VAPID key yet; the test serves it with a sample public key.
    page.route(f"http://127.0.0.1:{PORT}/index.html", lambda r: r.fulfill(status=200, content_type="text/html",
               body=INDEX.replace('const VAPID_PUBLIC = "";', f'const VAPID_PUBLIC = "{key}";')))
    errors = []
    page.on("pageerror", lambda e: errors.append(str(e)))
    init = ("window.__noPush = true;" if no_push else "") + FAKE + (f"__push.regFail = {str(reg_fail).lower()}; __push.perm = '{perm}';")
    if lang: init += f"try{{localStorage.setItem('lang','{lang}')}}catch(e){{}}"
    page.add_init_script(init)
    page.goto(f"http://127.0.0.1:{PORT}/index.html")
    page.wait_for_function("() => document.querySelector('#event').options.length > 1")
    time.sleep(0.2); page.evaluate("1")
    return ctx, page, calls, state, errors

shown = lambda p: p.evaluate("!document.querySelector('#push').hidden")
label = lambda p: p.inner_text("#pushBtn")
toast = lambda p: None if p.evaluate("document.querySelector('#toast').hidden") else p.inner_text("#toastTitle")
P = lambda p, k: p.evaluate(f"__push.{k}")
def settle(p, s=0.25): time.sleep(s); p.evaluate("1")

with sync_playwright() as pw:
    browser = pw.chromium.launch()

    # 1. the page as committed (no VAPID key): no button, nothing registered
    ctx, p, calls, state, errors = staff_page(browser, key="")
    check("no VAPID key: no button", not shown(p))
    check("no VAPID key: service worker not registered", P(p, "registered") is None)
    ctx.close()

    # 2. supported browser: button, note, nothing asked at load
    ctx, p, calls, state, errors = staff_page(browser)
    check("button shown, labelled Remind Me", shown(p) and label(p) == "Remind Me", label(p))
    check("note beside the button", "not guaranteed" in p.inner_text(".push-note"), p.inner_text(".push-note"))
    check("sw.js registered", P(p, "registered") == "sw.js")
    check("permission NOT asked at page load", P(p, "asked") == 0)

    # 3. sign up
    p.click("#pushBtn"); settle(p)
    b = calls["subscribe"][0] if calls["subscribe"] else {}
    check("permission asked inside the click", P(p, "asked") == 1)
    check("subscribed with the 65-byte public key", P(p, "subscribed") == 1 and P(p, "keyLength") == 65, P(p, "keyLength"))
    check("push_subscribe gets address, keys, device ID, language", b.get("p_endpoint") == "https://push.example.test/send/abc" and b.get("p_p256dh") == "BPkey123"
          and b.get("p_auth") == "authkey456" and str(b.get("p_device_id", "")).startswith("DEV-") and b.get("p_lang") == "en", b)
    check("no staff code sent when signing up", "p_staff_code" not in b and not calls["check_in"])
    check("signed up: button says Stop reminders, message says on", label(p) == "Stop reminders" and toast(p) == "Reminders on", (label(p), toast(p)))

    # 4. an accepted check-in links the phone, quietly and without delaying the message
    state["link_delay"] = 2.0
    p.click("#toastClose"); p.select_option("#event", "WEB1"); p.fill("#staff", "MNHA")
    t0 = time.time(); p.click("#go")
    p.wait_for_function("() => !document.querySelector('#toast').hidden", timeout=5000)
    quick = time.time() - t0
    check("check-in message not delayed by the link", toast(p) == "Attendance recorded" and quick < 1.5, (toast(p), round(quick, 2)))
    for r in state["held"]: r.fulfill(json={"ok": True})
    settle(p, 0.3)
    lk = calls["link"][0] if calls["link"] else {}
    check("push_link called after the accepted check-in", len(calls["link"]) == 1 and lk.get("p_endpoint") == "https://push.example.test/send/abc"
          and lk.get("p_device_id") == calls["check_in"][0]["p_device_id"], (calls["link"], calls["check_in"][:1]))
    check("push_link carries no staff code", "p_staff_code" not in lk)
    state["reply"] = {"ok": False, "reason": "outside_time_window"}; state["link_delay"] = 0
    p.click("#toastClose"); p.click("#go"); settle(p, 0.5)
    check("refused check-in: no push_link", len(calls["link"]) == 1, calls["link"])

    # 5. stop
    p.click("#toastClose"); p.click("#pushBtn"); settle(p)
    check("stop: browser subscription removed", P(p, "unsubscribed") == 1)
    check("stop: push_unsubscribe with the address", calls["unsubscribe"] == [{"p_endpoint": "https://push.example.test/send/abc"}], calls["unsubscribe"])
    check("stop: button back to Remind Me, message", label(p) == "Remind Me" and toast(p) == "Reminders stopped", (label(p), toast(p)))
    check("no errors", not errors, errors)
    ctx.close()

    # 7. permission refused
    ctx, p, calls, state, errors = staff_page(browser, perm="denied")
    p.click("#pushBtn"); settle(p)
    check("refused permission: message, nothing sent", toast(p) == "Notifications are blocked" and not calls["subscribe"] and P(p, "subscribed") == 0, toast(p))
    check("refused permission: button stays Remind Me", label(p) == "Remind Me")
    ctx.close()

    # 8. an older database (no push door): the button goes away and nothing is left subscribed
    ctx, p, calls, state, errors = staff_page(browser, push_status=404)
    p.click("#pushBtn"); settle(p)
    check("old database: button hidden after 404", not shown(p))
    check("old database: browser subscription undone", P(p, "unsubscribed") == 1)
    check("old database: no error message", toast(p) is None, toast(p))
    ctx.close()

    # 9. sw.js missing: no button, nothing breaks
    ctx, p, calls, state, errors = staff_page(browser, reg_fail=True)
    check("sw.js missing: no button", not shown(p))
    check("sw.js missing: page still works", p.evaluate("document.querySelector('#event').options.length") > 1 and not errors, errors)
    ctx.close()

    # 10. iPhone, page not opened from the Home Screen (no PushManager): the button explains instead of asking
    IPHONE = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
    ctx, p, calls, state, errors = staff_page(browser, no_push=True, ua=IPHONE)
    check("iPhone not from Home Screen: button shown", shown(p) and label(p) == "Remind Me")
    p.click("#pushBtn"); settle(p)
    check("iPhone: says Add to Home Screen first", toast(p) == "Add to Home Screen first", toast(p))
    check("iPhone: nothing sent", not calls["subscribe"])
    ctx.close()

    # 11. a browser without push (and not an iPhone): no button
    ctx, p, calls, state, errors = staff_page(browser, no_push=True)
    check("no push support: no button", not shown(p))
    ctx.close()

    # 12. BM
    ctx, p, calls, state, errors = staff_page(browser, lang="ms")
    check("BM: label is still Remind Me", label(p) == "Remind Me")
    p.click("#pushBtn"); settle(p)
    check("BM: stop label and message", label(p) == "Hentikan peringatan" and toast(p) == "Peringatan dihidupkan", (label(p), toast(p)))
    check("BM: language sent as ms", calls["subscribe"][0].get("p_lang") == "ms")
    check("BM: note", p.inner_text(".push-note").startswith("Peringatan membantu"))

    # 13. sw.js itself, run against a fake service-worker world
    # The page's own CSP blocks fetch() to its folder (connect-src is the database only), so the file is handed in.
    sw = p.evaluate("""async (code) => {
      const shown = [], opened = [], focused = [], handlers = {};
      const self = { addEventListener: (n, f) => handlers[n] = f,
        registration: { scope: location.origin + '/', showNotification: (t, o) => { shown.push([t, o]); return Promise.resolve(); } },
        clients: { matchAll: () => Promise.resolve([]), openWindow: u => { opened.push(u); return Promise.resolve(); } } };
      new Function('self', code)(self);
      let wait;
      handlers.push({ data: { json: () => ({ title: 'Kehadiran Staf', body: 'Kehadiran anda belum direkod.', kind: 'R2' }) }, waitUntil: p => wait = p });
      await wait;
      handlers.notificationclick({ notification: { close() {}, data: { url: './' } }, waitUntil: p => wait = p });
      await wait;
      return { title: shown[0][0], body: shown[0][1].body, tag: shown[0][1].tag, icon: shown[0][1].icon, opened };
    }""", open(ROOT + "/sw.js", encoding="utf-8").read())
    check("sw.js: shows title and words from the push", sw["title"] == "Kehadiran Staf" and sw["body"] == "Kehadiran anda belum direkod.", sw)
    check("sw.js: one notification per kind, school logo", sw["tag"] == "R2" and sw["icon"] == "logo.png", sw)
    check("sw.js: tap opens the staff page", sw["opened"] == [f"http://127.0.0.1:{PORT}/"], sw["opened"])
    check("no errors (BM)", not errors, errors)
    ctx.close()

    # 14. admin Settings: the count, owner and manager; hidden on an older database
    def admin(count_status):
        ctx = browser.new_context(viewport={"width": 1200, "height": 900}); page = ctx.new_page()
        def handle(route):
            path = route.request.url.split(".supabase.co", 1)[1]
            def rows(data): return route.fulfill(status=200, headers={"Content-Range": f"0-{max(len(data)-1,0)}/{len(data)}", "Content-Type": "application/json"}, body=json.dumps(data))
            if path.startswith("/auth/v1/token"): return route.fulfill(json={"access_token": "t", "refresh_token": "r", "expires_in": 3600, "user": {"email": "owner@local.test"}})
            if path.startswith("/auth/v1/"): return route.fulfill(json={})
            if "/rpc/admin_role" in path: return route.fulfill(json="manager")
            if "/rpc/push_count" in path: return route.fulfill(status=count_status, json={"phones": 23, "linked": 18} if count_status == 200 else {"code": "PGRST202"})
            if "/rpc/" in path: return route.fulfill(json=None)
            if path.startswith("/rest/v1/org_settings"): return rows([{"id": 1, "organization_name": "Test School", "max_gps_accuracy_m": 30, "qr_valid_seconds": 60}])
            return rows([])
        page.route("https://xtrgefkopnqgektrllra.supabase.co/**", handle)
        page.route("https://*.openstreetmap.org/**", lambda r: r.abort())
        errs = []; page.on("pageerror", lambda e: errs.append(str(e)))
        page.goto(f"http://127.0.0.1:{PORT}/admin.html#settings")
        page.fill("#email", "owner@local.test"); page.fill("#password", "local-test-only"); page.click("#loginGo")
        page.wait_for_selector("#view-settings:not([hidden]) h1"); time.sleep(0.4); page.evaluate("1")
        return ctx, page, errs
    ctx, p, errs = admin(200)
    line = p.evaluate("(() => { const e = document.querySelector('#setPush'); return e && !e.hidden ? e.textContent : null; })()")
    check("admin: Settings shows phones with reminders", line == "Phones with reminders: 23 (18 linked to a staff member)", line)
    p.evaluate("document.querySelector(\".lang button[data-lang='ms']\").click()"); time.sleep(0.2)
    check("admin: BM", p.inner_text("#setPush").startswith("Telefon dengan peringatan: 23"), p.inner_text("#setPush"))
    p.evaluate("document.querySelector('#menuBtn').click()"); time.sleep(0.1); p.evaluate("document.querySelector('#logout').click()"); time.sleep(0.2)
    check("admin: sign-out empties the count", p.evaluate("document.querySelector('#setPush') === null"))
    check("admin: no errors", not errs, errs)
    ctx.close()
    ctx, p, errs = admin(404)
    check("admin: older database, line hidden", p.evaluate("(() => { const e = document.querySelector('#setPush'); return !e || e.hidden; })()"))
    ctx.close()
    browser.close()
print(f"{sum(1 for _, ok in results if ok)} of {len(results)} passed")
