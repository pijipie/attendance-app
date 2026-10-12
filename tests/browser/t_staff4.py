import sys, time, threading, http.server, socketserver, functools
from playwright.sync_api import sync_playwright
# Staff page 2.12 (SQL file 15): the time out left today, shown only on the phone that checked in.
# Every call to Supabase is answered here; the phone's GPS is faked. Run: python3 tests/browser/t_staff4.py .
ROOT = sys.argv[1]; PORT = 8772
class Q(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a): pass
socketserver.TCPServer.allow_reuse_address = True
srv = socketserver.TCPServer(("127.0.0.1", PORT), functools.partial(Q, directory=ROOT))
threading.Thread(target=srv.serve_forever, daemon=True).start()

GEO = """
(() => {
  const w = { cb: new Map(), n: 0 };
  window.__geo = { w, emit(acc) { for (const [, c] of w.cb) c.ok({ coords: { latitude: 1.2346, longitude: 2.3457, accuracy: acc }, timestamp: Date.now() }); } };
  Object.defineProperty(navigator, "geolocation", { configurable: true, value: {
    watchPosition(ok, err) { const id = ++w.n; w.cb.set(id, { ok, err }); return id; },
    clearWatch(id) { w.cb.delete(id); }, getCurrentPosition() { throw new Error("not used"); } }});
})();
"""
EVENTS = [{"event_code": "0001", "name": "Daily Attendance", "require_qr": False, "open_now": True, "require_location": True, "audience": "all", "allow_exit": True}]
GENERAL = {"ok": True, "limit_minutes": 240, "work_start": "07:40", "work_end": "15:30", "now": "10:05", "open_now": True, "latest": "14:05"}
results = []
def check(name, cond, extra=""):
    results.append((name, bool(cond))); print(("PASS " if cond else "FAIL ") + name + (("  -> " + str(extra)) if (extra and not cond) else ""))

def new_page(browser, rules=None, old_db=False, lang=None):
    ctx = browser.new_context(viewport={"width": 390, "height": 800})
    page = ctx.new_page()
    calls = {"rules": [], "exit": []}
    state = {"rules": rules or GENERAL, "old_db": old_db, "xreply": None}
    def handle(route):
        url = route.request.url; body = route.request.post_data_json if route.request.post_data else {}
        if url.endswith("/rpc/list_events"): return route.fulfill(json=EVENTS)
        if url.endswith("/rpc/event_counter"): return route.fulfill(json={"window_label": "Pagi", "window_state": "open", "present": 4, "total": 70})
        if url.endswith("/rpc/exit_rules"):
            calls["rules"].append(body)
            # A database older than file 15 knows only exit_rules(p_event_code): PostgREST answers 404 to any other argument.
            if state["old_db"] and "p_device_id" in body: return route.fulfill(status=404, json={"code": "PGRST202"})
            return route.fulfill(json=state["rules"])
        if url.endswith("/rpc/work_exit"): calls["exit"].append(body); return route.fulfill(json=state["xreply"])
        return route.fulfill(status=404, json={})
    page.route("https://xtrgefkopnqgektrllra.supabase.co/**", handle)
    errors = []
    page.on("pageerror", lambda e: errors.append(str(e)))
    page.on("console", lambda m: errors.append(m.text) if m.type == "error" and "404" not in m.text and "Failed to load resource" not in m.text else None)
    page.clock.install()
    page.add_init_script(GEO + (f"try{{localStorage.setItem('lang','{lang}')}}catch(e){{}}" if lang else ""))
    page.goto(f"http://127.0.0.1:{PORT}/index.html")
    page.wait_for_function("() => document.querySelector('#event').options.length > 1")
    PAGE[0] = page
    return ctx, page, calls, state, errors

PAGE = [None]
def wait_calls(lst, n, timeout=2.0):
    t0 = time.time()
    while len(lst) < n and time.time() - t0 < timeout:
        time.sleep(0.03); PAGE[0].evaluate("1")      # a call into the page lets Playwright deliver the waiting network requests
    return len(lst) >= n
def fwd(p, ms): p.clock.run_for(ms); time.sleep(0.05)
def settle(p): time.sleep(0.15); p.evaluate("1")
note  = lambda p: p.inner_text("#exitNote") if p.evaluate("!document.querySelector('#exitNote').closest('[hidden]') && !document.querySelector('#exitNote').hidden") else None
toast = lambda p: None if p.evaluate("document.querySelector('#toast').hidden") else (p.inner_text("#toastTitle"), p.inner_text("#toastText"))
def to_out(p, calls, n=1):
    p.select_option("#event", "0001"); time.sleep(0.05)
    p.click(".seg button[data-act='out']"); wait_calls(calls["rules"], n); settle(p)
def lang(p, code): p.evaluate(f"document.querySelector(\".lang button[data-lang='{code}']\").click()"); time.sleep(0.05)   # by script: the floating message may cover the button on a 390 px screen
def ready(p): fwd(p, 100); p.evaluate("__geo.emit(8)"); fwd(p, 6000)

PERSONAL = dict(GENERAL, personal=True, minutes_left=149, latest="12:29")
with sync_playwright() as pw:
    browser = pw.chromium.launch()

    # 1. the device ID is sent, and the personal note is shown (EN, then BM)
    ctx, p, calls, state, errors = new_page(browser, rules=PERSONAL)
    to_out(p, calls)
    b = calls["rules"][0]
    check("exit_rules gets the event and this phone's device ID", b.get("p_event_code") == "0001" and str(b.get("p_device_id", "")).startswith("DEV-"), b)
    check("no staff code is sent to exit_rules", "p_staff_code" not in b, b)
    check("personal note EN", note(p) == "Time out left today: 2 h 29 min · back by 12:29 at the latest", note(p))
    lang(p, "ms")
    check("personal note BM", note(p) == "Baki keluar hari ini: 2 j 29 min · paling lewat kembali 12:29", note(p))
    lang(p, "en")

    # 2. under an hour, and nothing left
    state["rules"] = dict(PERSONAL, minutes_left=45, latest="10:50"); fwd(p, 60000); wait_calls(calls["rules"], 2); settle(p)
    check("under an hour: minutes only", note(p) == "Time out left today: 45 min · back by 10:50 at the latest", note(p))
    state["rules"] = dict(PERSONAL, minutes_left=0, latest="10:05"); fwd(p, 60000); wait_calls(calls["rules"], 3); settle(p)
    check("nothing left: 0 min", note(p) == "Time out left today: 0 min · back by 10:05 at the latest", note(p))

    # 3. out now, and gone home (EN and BM)
    state["rules"] = dict(PERSONAL, out_now=True, back_by="11:30"); fwd(p, 60000); wait_calls(calls["rules"], 4); settle(p)
    check("out-now note EN", note(p) == "You are still out (back by 11:30). Choose Back in.", note(p))
    lang(p, "ms")
    check("out-now note BM", note(p) == "Anda masih di luar (kembali sebelum 11:30). Pilih Masuk semula.", note(p))
    state["rules"] = dict(PERSONAL, gone_home=True); fwd(p, 60000); wait_calls(calls["rules"], 5); settle(p)
    check("gone-home note BM", note(p) == "Pulang sudah direkodkan hari ini.", note(p))
    lang(p, "en")
    check("gone-home note EN", note(p) == "Going home is already recorded today.", note(p))

    # 4. another phone: the general note, as before
    state["rules"] = GENERAL; fwd(p, 60000); wait_calls(calls["rules"], 6); settle(p)
    check("general note EN", note(p) is not None and "14:05" in note(p) and "left today" not in note(p), note(p))
    lang(p, "ms")
    check("general note BM", note(p) is not None and "14:05" in note(p) and "Baki" not in note(p), note(p))
    lang(p, "en")

    # 5. Keluar accepted: one more line with the time left if back on time; the note is asked for again
    # The minutes skipped above passed the page's two-minute battery rest, so the GPS is paused: press "Find my location", as a person would.
    check("GPS paused after the idle minutes", p.evaluate("document.querySelector('#gps').dataset.state") == "paused")
    p.click("#gpsRetry"); time.sleep(0.05)
    ready(p)
    state["xreply"] = {"ok": True, "action": "out", "going_home": False, "name": "Test One", "back_by": "11:30", "minutes_left_if_on_time": 210}
    n = len(calls["rules"])
    p.fill("#staff", "MNHA"); p.fill("#exitReason", "Ke bank"); p.fill("#exitBack", "11:30"); p.click("#go")
    wait_calls(calls["exit"], 1); settle(p)
    t = toast(p)
    check("out ok: second line EN", t and t[0] == "Step out recorded" and t[1].endswith("\nIf you are back at 11:30, time out left today: 3 h 30 min."), t)
    check("out ok: note asked for again", wait_calls(calls["rules"], n + 1), len(calls["rules"]))
    lang(p, "ms"); t = toast(p)
    check("out ok: second line BM (redrawn on language change)", t and t[1].endswith("\nJika kembali pada 11:30, baki hari ini 3 j 30 min."), t)
    lang(p, "en")

    # 6. Masuk semula accepted: one more line with the time left today
    p.click(".seg button[data-act='back']"); time.sleep(0.05); ready(p)
    state["xreply"] = {"ok": True, "action": "back", "name": "Test One", "away_minutes": 15, "late_minutes": None, "day_minutes": 15, "over_limit": False, "minutes_left": 225}
    p.click("#go"); wait_calls(calls["exit"], 2); settle(p)
    t = toast(p)
    check("back ok: second line EN", t and t[0] == "Back in recorded" and t[1].endswith("\nTime out left today: 3 h 45 min."), t)

    # 7. a reply without the new fields (older database): no second line
    p.click(".seg button[data-act='out']"); p.click(".seg button[data-act='back']"); time.sleep(0.05); ready(p)   # a fresh choice starts the GPS again
    state["xreply"] = {"ok": True, "action": "back", "name": "Test One", "away_minutes": 15, "late_minutes": None, "day_minutes": 30, "over_limit": False}
    p.click("#go"); wait_calls(calls["exit"], 3); settle(p)
    t = toast(p)
    check("older reply: no second line", t and "\n" not in t[1] and "left today" not in t[1], t)
    check("no errors", not errors, errors)
    ctx.close()

    # 8. a database older than file 15: 404 to the device ID -> asked again without it, general note
    ctx, p, calls, state, errors = new_page(browser, old_db=True)
    to_out(p, calls, 2)
    check("old database: first call had the device ID", "p_device_id" in calls["rules"][0], calls["rules"])
    check("old database: asked again without it", len(calls["rules"]) >= 2 and "p_device_id" not in calls["rules"][1], calls["rules"])
    check("old database: general note shown", note(p) is not None and "14:05" in note(p), note(p))
    fwd(p, 60000); wait_calls(calls["rules"], 3); settle(p)
    check("old database: device ID not sent again", all("p_device_id" not in b for b in calls["rules"][1:]), calls["rules"])
    check("no errors (old database)", not errors, errors)
    ctx.close()
    browser.close()
print(f"{sum(1 for _, ok in results if ok)} of {len(results)} passed")
