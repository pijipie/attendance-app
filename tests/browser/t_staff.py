import json, sys, time, threading, http.server, socketserver, functools, os
from playwright.sync_api import sync_playwright
ROOT = sys.argv[1]; PORT = 8765
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

def new_page(browser, reply=None, report_status=200, no_geo=False, remembered=None, lang=None):
    ctx = browser.new_context(viewport={"width":390,"height":800})
    page = ctx.new_page()
    calls = {"check_in": [], "report": [], "other": []}
    state = {"reply": reply or {"ok": True, "name": "Test One", "event": "Daily Attendance", "distance_m": 12}}
    def handle(route):
        url = route.request.url; body = route.request.post_data_json if route.request.post_data else {}
        if url.endswith("/rpc/list_events"): return route.fulfill(json=EVENTS)
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
    page.wait_for_function("document.querySelector('#event').options.length > 1")
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

with sync_playwright() as pw:
    b = pw.chromium.launch()

    # T1/T2: nothing until an event is chosen; then search, ready, instant submit, GPS rests after success
    ctx, p, calls, state, errors = new_page(b)
    check("T1 no event: line hidden, GPS not started", st(p) is None and geo(p)["starts"] == 0, (st(p), geo(p)))
    choose(p)
    check("T1 event chosen: searching, one search started", st(p) == "searching" and geo(p)["starts"] == 1, (st(p), geo(p)))
    p.evaluate("__geo.emit(12)"); fwd(p, 100)
    check("T2 good reading: 'Location found ±12 m'", st(p) == "ready" and "12" in txt(p) and "found" in txt(p), (st(p), txt(p)))
    submit(p)
    ok = wait_calls(calls["check_in"], 1)
    check("T2 submit sends at once with that reading", ok and calls["check_in"][0]["p_accuracy"] == 12 and calls["check_in"][0]["p_staff_code"] == "MNHA", calls["check_in"])
    time.sleep(0.2)
    check("T2 accepted: toast shown, GPS stopped, line hidden, no report", toast(p) == "Attendance recorded" and geo(p)["live"] == 0 and st(p) is None and not calls["report"], (toast(p), geo(p), st(p)))
    check("T2 form kept as it was", p.input_value("#staff") == "MNHA" and p.input_value("#event") == "0001")
    check("T2 no page errors", not errors, errors); ctx.close()

    # T3: a 25 m reading in the first second is held until the GPS has had 5 s
    ctx, p, calls, state, errors = new_page(b); choose(p)
    p.evaluate("__geo.emit(25)"); fwd(p, 500); submit(p); fwd(p, 2000)
    early = len(calls["check_in"])
    fwd(p, 3000); ok = wait_calls(calls["check_in"], 1)
    check("T3 25 m reading waits for the 5 s settle, then is sent", early == 0 and ok and calls["check_in"][0]["p_accuracy"] == 25, (early, calls["check_in"])); ctx.close()

    # T3b: a sharp reading (<=15 m) arriving during the wait is sent immediately
    ctx, p, calls, state, errors = new_page(b); choose(p)
    p.evaluate("__geo.emit(40)"); fwd(p, 500); submit(p); fwd(p, 1000)
    p.evaluate("__geo.emit(9)"); fwd(p, 400); ok = wait_calls(calls["check_in"], 1)
    check("T3b sharper reading during the wait is used at once", ok and calls["check_in"][0]["p_accuracy"] == 9, calls["check_in"]); ctx.close()

    # T4: weak signal is shown, still sent after the wait, and the database's refusal is explained
    ctx, p, calls, state, errors = new_page(b, reply={"ok": False, "reason": "gps_accuracy_too_low"}); choose(p)
    p.evaluate("__geo.emit(40)"); fwd(p, 1000)
    check("T4 weak: line says weak ±40 m", st(p) == "weak" and "40" in txt(p), (st(p), txt(p)))
    submit(p)
    for _ in range(25):
        p.evaluate("__geo.emit(40)"); fwd(p, 1000)
        if calls["check_in"]: break
    ok = wait_calls(calls["check_in"], 1); time.sleep(0.2)
    check("T4 weak reading goes to the database after the wait; toast 'GPS signal too weak'", ok and toast(p) == "GPS signal too weak", (calls["check_in"], toast(p)))
    check("T4 after a refusal the search carries on", geo(p)["live"] == 1 and st(p) in ("weak", "searching"), (geo(p), st(p))); ctx.close()

    # T5: 2,000 m = approximate location: own words on the line and in the toast
    ctx, p, calls, state, errors = new_page(b, reply={"ok": False, "reason": "gps_accuracy_too_low"}); choose(p)
    p.evaluate("__geo.emit(2000)"); fwd(p, 1000)
    check("T5 approximate: line says approximate + Precise location", st(p) == "approx" and "Precise" in txt(p), (st(p), txt(p)))
    submit(p)
    for _ in range(25):
        p.evaluate("__geo.emit(2000)"); fwd(p, 1000)
        if calls["check_in"]: break
    wait_calls(calls["check_in"], 1); time.sleep(0.2)
    check("T5 toast 'Precise location is off' with the figure", toast(p) == "Precise location is off" and "2000" in p.inner_text("#toastText"), (toast(p),)); ctx.close()

    # T6: blocked. Line + Try again, quick answer on submit, reported once
    ctx, p, calls, state, errors = new_page(b); choose(p)
    p.evaluate("__geo.fail(1)"); fwd(p, 100)
    check("T6 blocked: line says blocked, Try again visible", st(p) == "denied" and p.is_visible("#gpsRetry") and p.inner_text("#gpsRetry") == "Try again", (st(p),))
    submit(p); p.evaluate("__geo.fail(1)"); fwd(p, 600); ok = wait_calls(calls["report"], 1); time.sleep(0.1)
    check("T6 submit: toast 'Location access denied', nothing sent to check_in", toast(p) == "Location access denied" and not calls["check_in"], (toast(p), calls["check_in"]))
    check("T6 reported: kind denied, staff, event, device", ok and calls["report"][0]["p_kind"] == "denied" and calls["report"][0]["p_staff_code"] == "MNHA" and calls["report"][0]["p_event_code"] == "0001" and calls["report"][0]["p_device_id"].startswith("DEV-"), calls["report"])
    p.click("#go"); time.sleep(0.05); p.evaluate("__geo.fail(1)"); fwd(p, 600); time.sleep(0.2)
    check("T6 second press: not reported twice", len(calls["report"]) == 1, calls["report"])
    check("T6 no page errors", not errors, errors); ctx.close()

    # T7: device gives no location (switched off)
    ctx, p, calls, state, errors = new_page(b); choose(p)
    p.evaluate("__geo.fail(2)"); fwd(p, 9000)
    check("T7 off: line says no location from this device", st(p) == "off" and "GPS" in txt(p), (st(p), txt(p)))
    submit(p); fwd(p, 600); ok = wait_calls(calls["report"], 1); time.sleep(0.1)
    check("T7 submit answers at once (problem already lasted 8 s): toast + report 'off'", toast(p) == "No location from this device" and ok and calls["report"][0]["p_kind"] == "off", (toast(p), calls["report"]))
    p.evaluate("__geo.emit(10)"); fwd(p, 100)
    check("T7 a reading later clears the problem", st(p) == "ready", st(p)); ctx.close()

    # T8: GPS never answers
    ctx, p, calls, state, errors = new_page(b); choose(p); fwd(p, 21000)
    check("T8 no answer after 20 s: line says no location yet + Try again", st(p) == "timeout" and p.is_visible("#gpsRetry"), (st(p),))
    submit(p); fwd(p, 5000); mid = toast(p); fwd(p, 4000); ok = wait_calls(calls["report"], 1); time.sleep(0.1)
    check("T8 submit waits 8 s more, then 'Location not found' + report 'timeout'", mid is None and toast(p) == "Location not found" and ok and calls["report"][0]["p_kind"] == "timeout", (mid, toast(p), calls["report"]))
    p.click("#gpsRetry"); time.sleep(0.05)
    check("T8 Try again starts a new search", st(p) == "searching" and geo(p)["starts"] >= 2 and geo(p)["live"] == 1, (st(p), geo(p))); ctx.close()

    # T9: a reading that has gone stale is never sent
    ctx, p, calls, state, errors = new_page(b); choose(p)
    p.evaluate("__geo.emit(10)"); fwd(p, 100); before = geo(p)["starts"]
    fwd(p, 30000)
    check("T9 old reading: line goes back to searching", st(p) == "searching", st(p))
    submit(p); fwd(p, 1000)
    check("T9 submit with only an old reading: new search started, nothing sent yet", geo(p)["starts"] == before + 1 and not calls["check_in"], (geo(p), calls["check_in"]))
    p.evaluate("__geo.emit(11, 1.2347, 2.3465)"); fwd(p, 400); ok = wait_calls(calls["check_in"], 1)
    check("T9 the NEW reading is the one sent", ok and calls["check_in"][0]["p_accuracy"] == 11 and abs(calls["check_in"][0]["p_lng"] - 2.3465) < 1e-9, calls["check_in"]); ctx.close()

    # T10: idle for two minutes -> GPS paused, button brings it back
    ctx, p, calls, state, errors = new_page(b); choose(p)
    p.evaluate("__geo.emit(10)"); fwd(p, 121000)
    check("T10 idle 2 min: paused, GPS stopped, 'Find my location'", st(p) == "paused" and geo(p)["live"] == 0 and p.inner_text("#gpsRetry") == "Find my location", (st(p), geo(p)))
    p.click("#gpsRetry"); time.sleep(0.05)
    check("T10 button restarts the search", st(p) == "searching" and geo(p)["live"] == 1, (st(p), geo(p))); ctx.close()

    # T11: older database (no report door): silent, and the page stops knocking
    ctx, p, calls, state, errors = new_page(b, report_status=404); choose(p)
    p.evaluate("__geo.fail(1)"); fwd(p, 100); submit(p); p.evaluate("__geo.fail(1)"); fwd(p, 600); wait_calls(calls["report"], 1); time.sleep(0.2)
    p.fill("#staff", "NSMS"); p.click("#go"); time.sleep(0.05); p.evaluate("__geo.fail(1)"); fwd(p, 600); time.sleep(0.2)
    check("T11 no report door: toast still shown, one knock only, no page errors", toast(p) == "Location access denied" and len(calls["report"]) == 1 and not errors, (toast(p), calls["report"], errors)); ctx.close()

    # T12: Bahasa Melayu + remembered event starts the search on load
    ctx, p, calls, state, errors = new_page(b, remembered="0001", lang="ms"); time.sleep(0.2)
    check("T12 remembered event: search starts on load, BM words", st(p) == "searching" and txt(p) == "Mencari lokasi…", (st(p), txt(p)))
    p.evaluate("__geo.emit(12)"); fwd(p, 100)
    check("T12 BM ready line", txt(p) == "Lokasi ditemui · ±12 m", txt(p))
    p.click(".lang button[data-lang='en']"); time.sleep(0.05)
    check("T12 language switch redraws the line", txt(p) == "Location found · ±12 m", txt(p)); ctx.close()

    # T13: page out of sight -> GPS off; back -> on
    ctx, p, calls, state, errors = new_page(b); choose(p); p.evaluate("__geo.emit(10)"); fwd(p, 100)
    p.evaluate("Object.defineProperty(document,'hidden',{configurable:true,get:()=>true}); document.dispatchEvent(new Event('visibilitychange'))"); time.sleep(0.05)
    off = geo(p)["live"]
    p.evaluate("Object.defineProperty(document,'hidden',{configurable:true,get:()=>false}); document.dispatchEvent(new Event('visibilitychange'))"); time.sleep(0.05)
    check("T13 hidden: GPS stopped; visible again: searching", off == 0 and geo(p)["live"] == 1 and st(p) == "searching", (off, geo(p), st(p))); ctx.close()

    # T14: outside the area: the extra hint
    ctx, p, calls, state, errors = new_page(b, reply={"ok": False, "reason": "outside_geofence", "distance_m": 75.2}); choose(p)
    p.evaluate("__geo.emit(9)"); fwd(p, 100); submit(p); wait_calls(calls["check_in"], 1); time.sleep(0.2)
    t = p.inner_text("#toastText")
    check("T14 outside: distance + 'Already there? Step outdoors'", toast(p) == "You are outside the area" and "75 m" in t and "Already there?" in t and not calls["report"], (toast(p), t)); ctx.close()

    # T15: browser without geolocation
    ctx, p, calls, state, errors = new_page(b, no_geo=True); choose(p)
    check("T15 unsupported: line says so, no button", st(p) == "unsupported" and not p.is_visible("#gpsRetry"), (st(p),))
    submit(p); fwd(p, 300); ok = wait_calls(calls["report"], 1); time.sleep(0.1)
    check("T15 submit: toast + report 'unsupported'", toast(p) == "Location not supported" and ok and calls["report"][0]["p_kind"] == "unsupported" and not errors, (toast(p), calls["report"], errors)); ctx.close()

    # T16: changing the event after success starts looking again; back to "choose" is impossible, so test second event
    ctx, p, calls, state, errors = new_page(b); choose(p); p.evaluate("__geo.emit(10)"); fwd(p, 100); submit(p); wait_calls(calls["check_in"], 1); time.sleep(0.2)
    choose(p, "0002")
    check("T16 another event after success: searching again", st(p) == "searching" and geo(p)["live"] == 1, (st(p), geo(p))); ctx.close()

    # words: both languages have the same keys
    ctx, p, calls, state, errors = new_page(b)
    same = p.evaluate("(() => { const k = o => Object.keys(o).sort().join(); return k(TEXT.ms) === k(TEXT.en) && k(MESSAGES.ms) === k(MESSAGES.en) && !('gps' in TEXT.en); })()")
    check("words: BM and EN have identical keys; old 'gps' text gone", same); ctx.close()
    b.close()
bad = [n for n, ok in results if not ok]
print(f"\n{len(results) - len(bad)} of {len(results)} passed"); sys.exit(1 if bad else 0)
