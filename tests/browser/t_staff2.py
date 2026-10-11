import json, sys, time, threading, http.server, socketserver, functools, os
from playwright.sync_api import sync_playwright
ROOT = sys.argv[1]; PORT = 8768
class Q(http.server.SimpleHTTPRequestHandler):
    def log_message(self,*a): pass
socketserver.TCPServer.allow_reuse_address = True
srv = socketserver.TCPServer(("127.0.0.1", PORT), functools.partial(Q, directory=ROOT))
threading.Thread(target=srv.serve_forever, daemon=True).start()

GEO = """
(() => {
  const w = { cb: new Map(), n: 0, starts: 0, clears: 0 };
  window.__geo = {
    w,
    emit(acc, lat=1.2346, lng=2.3457) { for (const [, c] of w.cb) c.ok({ coords: { latitude: lat, longitude: lng, accuracy: acc }, timestamp: Date.now() }); },
    fail(code) { for (const [, c] of [...w.cb]) c.err({ code, message: "x" }); },
  };
  if (!window.__noGeo) Object.defineProperty(navigator, "geolocation", { configurable: true, value: {
    watchPosition(ok, err) { const id = ++w.n; w.cb.set(id, { ok, err }); w.starts++; return id; },
    clearWatch(id) { if (w.cb.delete(id)) w.clears++; },
    getCurrentPosition() { throw new Error("not used"); }
  }});
})();
"""
EVENTS = [{"event_code":"0001","name":"Daily Attendance","require_qr":False,"open_now":True},
          {"event_code":"0002","name":"Meeting","require_qr":False,"open_now":True}]
results = []
def check(name, cond, extra=""):
    results.append((name, bool(cond))); print(("PASS " if cond else "FAIL ") + name + (("  -> " + str(extra)) if (extra and not cond) else ""))

def new_page(browser, reply=None, report_status=200, no_geo=False, remembered=None, lang=None, events=None, list_fails=False):
    ctx = browser.new_context(viewport={"width":390,"height":800})
    page = ctx.new_page()
    calls = {"check_in": [], "report": [], "other": []}
    state = {"reply": reply or {"ok": True, "name": "Test One", "event": "Daily Attendance", "distance_m": 12}, "events": events or EVENTS, "list_fails": list_fails}
    def handle(route):
        url = route.request.url; body = route.request.post_data_json if route.request.post_data else {}
        if url.endswith("/rpc/list_events"):
            calls["other"].append("list_events")
            return route.fulfill(status=500, json={}) if state.get("list_fails") else route.fulfill(json=state["events"])
        if url.endswith("/rpc/event_counter"): return route.fulfill(json={"window_label":"Pagi","window_state":"open","present":4,"total":70})
        if url.endswith("/rpc/check_in"): calls["check_in"].append(body); return route.fulfill(json=state["reply"])
        if url.endswith("/rpc/report_location_problem"):
            calls["report"].append(body)
            return route.fulfill(status=report_status, json={"ok": True} if report_status == 200 else {"message":"nope"})
        calls["other"].append(url); return route.fulfill(status=404, json={})
    page.route("https://xtrgefkopnqgektrllra.supabase.co/**", handle)
    errors = []
    page.on("pageerror", lambda e: errors.append(str(e)))
    page.on("console", lambda m: errors.append(m.text) if m.type == "error" and "404" not in m.text and "Failed to load resource" not in m.text else None)
    page.clock.install()
    init = ("window.__noGeo = true; Object.defineProperty(navigator,'geolocation',{configurable:true,value:undefined});" if no_geo else "") + GEO
    if remembered: init += f"try{{localStorage.setItem('event_code','{remembered}')}}catch(e){{}}"
    if lang: init += f"try{{localStorage.setItem('lang','{lang}')}}catch(e){{}}"
    page.add_init_script(init)
    page.goto(f"http://127.0.0.1:{PORT}/index.html")
    page.wait_for_function("() => document.querySelector('#event').options.length > 1 || !document.querySelector('#codeField').hidden")
    PAGE[0] = page
    return ctx, page, calls, state, errors

st   = lambda p: p.evaluate("(() => { const b = document.querySelector('#gps'); return b.hidden ? null : b.dataset.state; })()")
txt  = lambda p: p.inner_text("#gpsText")
geo  = lambda p: p.evaluate("({starts: __geo.w.starts, clears: __geo.w.clears, live: __geo.w.cb.size})")
toast= lambda p: (p.inner_text("#toastTitle") if not p.evaluate("document.querySelector('#toast').hidden") else None)
def settle(p, ms=150): p.wait_for_timeout(ms) if False else time.sleep(ms/1000)
def fwd(p, ms): p.clock.run_for(ms); time.sleep(0.05)
def choose(p, code="0001"): p.select_option("#event", code); time.sleep(0.05)
def submit(p, code="MNHA"): p.fill("#staff", code); p.click("#go"); time.sleep(0.05)
PAGE = [None]
def wait_calls(lst, n, timeout=2.0):
    t0 = time.time()
    while len(lst) < n and time.time() - t0 < timeout:
        time.sleep(0.03); PAGE[0].evaluate("1")      # a call into the page lets Playwright deliver the waiting network requests
    return len(lst) >= n


EV3 = [{"event_code":"0001","name":"Daily Attendance","require_qr":False,"open_now":True,"require_location":True,"audience":"all"},
       {"event_code":"WEB1","name":"Online Briefing","require_qr":False,"open_now":True,"require_location":False,"audience":"all"},
       {"event_code":"SEL1","name":"Committee","require_qr":False,"open_now":True,"require_location":True,"audience":"selected"}]
NOLOC_OK = {"ok": True, "name": "Test One", "event": "Online Briefing", "distance_m": None}
ttext = lambda p: p.inner_text("#toastText")
hint  = lambda p: (p.inner_text("#hint") if p.is_visible("#hint") else "")
with sync_playwright() as pw:
    b = pw.chromium.launch()

    # N1: location off -> no search, no position sent
    ctx, p, calls, state, errors = new_page(b, events=EV3, reply=NOLOC_OK); choose(p, "WEB1")
    check("N1 location off: NO location line at all, GPS never started, page text never mentions location being off", st(p) is None and not p.is_visible("#gps") and geo(p)["starts"] == 0 and "does not need" not in p.inner_text("main").lower() and "tidak memerlukan" not in p.inner_text("main").lower(), (st(p), geo(p)))
    submit(p); ok = wait_calls(calls["check_in"], 1); time.sleep(0.2)
    c = calls["check_in"][0] if ok else {}
    check("N1 submit at once with NO position (all three empty)", ok and c["p_lat"] is None and c["p_lng"] is None and c["p_accuracy"] is None and c["p_event_code"] == "WEB1", c)
    check("N1 answer without a distance: 'Attendance recorded', name and event only", toast(p) == "Attendance recorded" and ttext(p) == "Test One · Online Briefing" and geo(p)["starts"] == 0 and not calls["report"] and not errors, (toast(p), ttext(p), errors)); ctx.close()

    # N2: location off on a device with no geolocation at all: still works
    ctx, p, calls, state, errors = new_page(b, events=EV3, reply=NOLOC_OK, no_geo=True); choose(p, "WEB1")
    submit(p); ok = wait_calls(calls["check_in"], 1); time.sleep(0.2)
    check("N2 device without location can still record a location-off event", ok and toast(p) == "Attendance recorded" and st(p) is None and not calls["report"] and not errors, (toast(p), st(p), errors)); ctx.close()

    # N3: switching between events starts and stops the search
    ctx, p, calls, state, errors = new_page(b, events=EV3); choose(p, "0001"); a = geo(p)
    choose(p, "WEB1"); c2 = geo(p); s2 = st(p)
    choose(p, "0001"); d = geo(p)
    check("N3 location event -> search on; location-off event -> search off; back -> on again", a["live"] == 1 and c2["live"] == 0 and s2 is None and d["live"] == 1 and st(p) == "searching", (a, c2, s2, d, st(p))); ctx.close()

    # N4: selected-staff event: hint, and the two "not on the list" answers
    ctx, p, calls, state, errors = new_page(b, events=EV3, reply={"ok": True, "name": "Test One", "event": "Committee", "distance_m": 9, "not_listed": True}); choose(p, "SEL1")
    check("N4 selected-staff event: hint says it is for invited staff", "invited staff" in hint(p), hint(p))
    p.evaluate("__geo.emit(9)"); fwd(p, 100); submit(p); wait_calls(calls["check_in"], 1); time.sleep(0.2)
    check("N4 not on the list: recorded, amber, says so", toast(p) == "Recorded, name not on the list" and "not on the list for this event" in ttext(p) and "warn" in p.get_attribute("#toast", "class"), (toast(p), ttext(p)))
    ctx.close()
    ctx, p, calls, state, errors = new_page(b, events=EV3, reply={"ok": True, "name": "Test One", "event": "Committee", "distance_m": 9, "not_listed": True, "late": True, "late_minutes": 12, "late_after": "07:40"}); choose(p, "SEL1")
    p.evaluate("__geo.emit(9)"); fwd(p, 100); submit(p); wait_calls(calls["check_in"], 1); time.sleep(0.2)
    check("N4 late AND not on the list: both said", toast(p) == "Recorded as late, name not on the list" and "12 min late (after 07:40)" in ttext(p), (toast(p), ttext(p))); ctx.close()
    ctx, p, calls, state, errors = new_page(b, events=EV3, reply={"ok": True, "name": "Test One", "event": "Committee", "distance_m": 9}); choose(p, "SEL1")
    p.evaluate("__geo.emit(9)"); fwd(p, 100); submit(p); wait_calls(calls["check_in"], 1); time.sleep(0.2)
    check("N4 on the list: the ordinary answer with distance", toast(p) == "Attendance recorded" and "9 m from the location" in ttext(p), (toast(p), ttext(p))); ctx.close()

    # N5: event list could not be loaded (code typed by hand) + phone has no position
    ctx, p, calls, state, errors = new_page(b, list_fails=True, reply=NOLOC_OK)
    p.fill("#eventCode", "WEB1"); p.dispatch_event("#eventCode", "change"); time.sleep(0.05)
    p.evaluate("__geo.fail(1)"); fwd(p, 100)
    p.fill("#staff", "MNHA"); p.click("#go"); time.sleep(0.05); p.evaluate("__geo.fail(1)"); fwd(p, 600)
    ok = wait_calls(calls["check_in"], 1); time.sleep(0.2)
    check("N5 unknown event + no position: the database is asked anyway, with no position; it accepts (location off)", ok and calls["check_in"][0]["p_lat"] is None and toast(p) == "Attendance recorded" and not calls["report"], (calls["check_in"], toast(p), calls["report"])); ctx.close()
    ctx, p, calls, state, errors = new_page(b, list_fails=True, reply={"ok": False, "reason": "location_required"})
    p.fill("#eventCode", "0001"); p.dispatch_event("#eventCode", "change"); time.sleep(0.05)
    p.evaluate("__geo.fail(1)"); fwd(p, 100)
    p.fill("#staff", "MNHA"); p.click("#go"); time.sleep(0.05); p.evaluate("__geo.fail(1)"); fwd(p, 600)
    wait_calls(calls["check_in"], 1); wait_calls(calls["report"], 1); time.sleep(0.2)
    check("N5 ...and when the database says a position WAS needed: the phone's own problem is shown and reported", toast(p) == "Location access denied" and len(calls["report"]) == 1 and calls["report"][0]["p_kind"] == "denied", (toast(p), calls["report"])); ctx.close()

    # N6: the list on the page is old: admin switched location ON meanwhile
    ctx, p, calls, state, errors = new_page(b, events=EV3, reply={"ok": False, "reason": "location_required"}); choose(p, "WEB1")
    state["events"] = [dict(e, require_location=True) if e["event_code"] == "WEB1" else e for e in EV3]
    submit(p); wait_calls(calls["check_in"], 1)
    for _ in range(10):
        time.sleep(0.1); p.evaluate("1")
        if toast(p): break
    check("N6 stale list: 'Location needed', list re-read, search for the phone started, nothing reported", toast(p) == "Location needed" and st(p) == "searching" and geo(p)["live"] == 1 and not calls["report"] and not errors, (toast(p), st(p), geo(p), errors))
    state["reply"] = {"ok": True, "name": "Test One", "event": "Online Briefing", "distance_m": 7}
    p.evaluate("__geo.emit(7)"); fwd(p, 100); p.click("#go"); time.sleep(0.05); wait_calls(calls["check_in"], 2); time.sleep(0.2)
    check("N6 second press sends the position", len(calls["check_in"]) == 2 and calls["check_in"][1]["p_accuracy"] == 7 and toast(p) == "Attendance recorded", (calls["check_in"], toast(p))); ctx.close()

    # N7: Bahasa Melayu
    ctx, p, calls, state, errors = new_page(b, events=EV3, reply={"ok": True, "name": "Test One", "event": "Committee", "distance_m": 9, "not_listed": True}, lang="ms"); choose(p, "WEB1")
    a = st(p); choose(p, "SEL1"); h2 = hint(p); p.evaluate("__geo.emit(9)"); fwd(p, 100); submit(p); wait_calls(calls["check_in"], 1); time.sleep(0.2)
    check("N7 BM: no line for a location-off event; hint and answer in BM", a is None and "staf yang dijemput" in h2 and toast(p) == "Direkodkan, nama tiada dalam senarai", (a, h2, toast(p)))
    same = p.evaluate("(() => { const k = o => Object.keys(o).sort().join(); return k(TEXT.ms) === k(TEXT.en) && k(MESSAGES.ms) === k(MESSAGES.en); })()")
    check("words: BM and EN have identical keys", same); ctx.close()
    b.close()
bad = [n for n, ok in results if not ok]
print(f"\n{len(results) - len(bad)} of {len(results)} passed"); sys.exit(1 if bad else 0)
