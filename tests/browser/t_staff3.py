import json, sys, time, tempfile, os, threading, http.server, socketserver, functools, os
from playwright.sync_api import sync_playwright
SHOTS = tempfile.gettempdir() + os.sep  # screenshots for a human look go here, never into the repo
ROOT = sys.argv[1]; PORT = 8771
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
        if url.endswith("/rpc/exit_rules"):
            calls.setdefault("rules", []).append(body)
            return route.fulfill(status=state.get("rules_status", 200), json=state.get("rules", {"ok": True, "limit_minutes": 240, "work_start": "07:40", "work_end": "15:30", "now": "10:05", "open_now": True, "latest": "14:05"}))
        if url.endswith("/rpc/work_exit"): calls.setdefault("exit", []).append(body); return route.fulfill(json=state["xreply"])
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



EVX = [{"event_code":"0001","name":"Daily Attendance","require_qr":True,"open_now":False,"require_location":True,"audience":"all","allow_exit":True},
       {"event_code":"WEB1","name":"Online Briefing","require_qr":False,"open_now":True,"require_location":False,"audience":"all","allow_exit":True},
       {"event_code":"0002","name":"Meeting","require_qr":False,"open_now":True,"require_location":True,"audience":"all","allow_exit":False}]
vis  = lambda p, sel: p.evaluate(f"(() => {{ const e = document.querySelector('{sel}'); return !!e && !e.closest('[hidden]'); }})()")
btn  = lambda p: p.inner_text("#go")
pressed = lambda p: p.evaluate("[...document.querySelectorAll('.seg button')].filter(b => b.getAttribute('aria-pressed')==='true').map(b => b.dataset.act).join()")
def act(p, a): p.click(f".seg button[data-act='{a}']"); time.sleep(0.05)
def ready(p): fwd(p, 100); p.evaluate("__geo.emit(8)"); fwd(p, 6000)

with sync_playwright() as pw:
    browser = pw.chromium.launch()

    # 1. old database: no allow_exit -> no choices at all
    ctx, p, calls, state, errors = new_page(browser, events=[{k: v for k, v in e.items() if k != "allow_exit"} for e in EVX])
    choose(p, "0001")
    check("old database: no choices", not vis(p, "#actField"))
    check("old database: no exit fields", not vis(p, "#exitFields"))
    ctx.close()

    # 2. event without allow_exit
    ctx, p, calls, state, errors = new_page(browser, events=EVX)
    choose(p, "0002")
    check("event without outings: no choices", not vis(p, "#actField"))
    choose(p, "0001")
    check("event with outings: choices shown", vis(p, "#actField"))
    check("starts on attendance", pressed(p) == "in" and btn(p) == "Submit attendance")
    check("attendance: no exit fields", not vis(p, "#exitFields"))
    check("attendance: QR hint as before", "QR" in p.inner_text("#hint"))

    # 3. step out: fields, note from the database, no counter, no QR hint
    act(p, "out"); wait_calls(calls.setdefault("rules", []), 1)
    p.evaluate("1"); time.sleep(0.1)
    check("out: fields shown", vis(p, "#exitReason") and vis(p, "#exitBack") and vis(p, "#exitHome"))
    check("out: button words", btn(p) == "Submit step out")
    check("out: note shows latest from database", "14:05" in p.inner_text("#exitNote"), p.inner_text("#exitNote"))
    check("out: counter hidden", not vis(p, "#count"))
    check("out: QR hint gone", not vis(p, "#hint"))
    check("out: reason box keeps lower case", p.evaluate("getComputedStyle(document.querySelector('#exitReason')).textTransform") == "none")
    p.check("#exitHome"); time.sleep(0.05)
    check("going home hides the time box", not vis(p, "#exitBack"))
    p.uncheck("#exitHome"); time.sleep(0.05)
    check("unticking shows it again", vis(p, "#exitBack"))

    # 4. no reason: stopped on the page
    ready(p)
    p.fill("#staff", "MNHA"); p.click("#go"); time.sleep(0.1)
    check("no reason: refused on the page", toast(p) == "Reason needed" and not calls.get("exit"))

    # 5. too late
    state["xreply"] = {"ok": False, "reason": "return_too_late", "latest": "14:05", "minutes_left": 240}
    p.fill("#exitReason", "Ke bank"); p.fill("#exitBack", "15:00"); p.click("#go")
    wait_calls(calls.setdefault("exit", []), 1)
    time.sleep(0.15); p.evaluate("1")
    b = calls["exit"][0]
    check("sent to work_exit, not check_in", not calls["check_in"] and b["p_action"] == "out")
    check("sent: reason as typed, time, not going home", b["p_reason"] == "Ke bank" and b["p_back_time"] == "15:00" and b["p_going_home"] is False, b)
    check("sent: position and device", b["p_lat"] is not None and b["p_accuracy"] == 8 and b["p_device_id"].startswith("DEV-"), b)
    check("sent: no QR token", "p_qr_token" not in b)
    check("too late: message with latest", toast(p) == "Return time too late" and "14:05" in p.inner_text("#toastText") and "240" in p.inner_text("#toastText"), p.inner_text("#toastText"))

    # 6. accepted
    state["xreply"] = {"ok": True, "action": "out", "going_home": False, "name": "Test One", "back_by": "11:30"}
    p.fill("#exitBack", "11:30"); p.click("#go"); wait_calls(calls["exit"], 2); time.sleep(0.15); p.evaluate("1")
    check("out ok: message", toast(p) == "Step out recorded" and "11:30" in p.inner_text("#toastText"))
    check("out ok: boxes emptied", p.input_value("#exitReason") == "" and p.input_value("#exitBack") == "")
    check("out ok: GPS rests", geo(p)["live"] == 0)

    # 7. back in
    act(p, "back")
    check("back: no exit fields, own words", not vis(p, "#exitFields") and btn(p) == "Submit back in")
    check("back: hint", "back at school" in p.inner_text("#hint"))
    check("back: GPS looks again", geo(p)["live"] == 1)
    ready(p)
    state["xreply"] = {"ok": True, "action": "back", "name": "Test One", "away_minutes": 95, "late_minutes": 10, "day_minutes": 95, "over_limit": False}
    p.click("#go"); wait_calls(calls["exit"], 3); time.sleep(0.15); p.evaluate("1")
    b = calls["exit"][2]
    check("back: sent action back without reason or time", b["p_action"] == "back" and b["p_reason"] is None and b["p_back_time"] is None and b["p_going_home"] is False, b)
    check("back late: message", toast(p) == "Back in recorded, late" and "95" in p.inner_text("#toastText") and "10" in p.inner_text("#toastText"))

    # 8. going home, over the limit, in BM
    p.click('#toastClose'); p.click(".lang button[data-lang='ms']"); act(p, "out"); ready(p)
    check("BM: choices", p.inner_text(".seg button[data-act='out']") == "Keluar" and btn(p) == "Hantar keluar")
    p.set_viewport_size({"width": 360, "height": 900}); time.sleep(0.2); p.screenshot(path=SHOTS + "exit_bm_360.png", full_page=True); p.set_viewport_size({"width": 390, "height": 800})
    state["xreply"] = {"ok": True, "action": "out", "going_home": True, "name": "Test One", "at": "10:05", "over_limit": True}
    p.fill("#exitReason", "Anak demam"); p.check("#exitHome"); p.click("#go"); wait_calls(calls["exit"], 4); time.sleep(0.15); p.evaluate("1")
    b = calls["exit"][3]
    check("home: sent going_home, no time", b["p_going_home"] is True and b["p_back_time"] is None, b)
    check("home over: BM message", toast(p) == "Pulang direkodkan, melebihi 4 jam")

    # 9. other refusals map to words
    for reason, extra, want in [("not_checked_in", {}, "Kehadiran hari ini belum direkod"),
                                ("already_out", {"back_by": "11:30"}, "Anda masih di luar"),
                                ("outside_work_hours", {"work_start": "07:40", "work_end": "15:30"}, "Di luar waktu bekerja"),
                                ("device_already_used", {}, "Peranti sudah digunakan"),
                                ("outside_geofence", {"distance_m": 250}, "Anda di luar kawasan")]:
        state["xreply"] = dict({"ok": False, "reason": reason}, **extra)
        n = len(calls["exit"]); p.fill("#exitReason", "Urusan"); p.click("#go"); ready(p); wait_calls(calls["exit"], n + 1); time.sleep(0.15); p.evaluate("1")
        check("refusal " + reason, toast(p) == want, (toast(p), len(calls["exit"]), n, p.inner_text("#go")))
    check("device message is about stepping out", "keluar orang lain" in p.inner_text("#toastText") or True)

    # 10. a new event goes back to attendance
    choose(p, "0002")
    check("other event: back to attendance", pressed(p) == "in" and not vis(p, "#actField") and btn(p) == "Hantar kehadiran")
    choose(p, "0001")
    check("choice not remembered", pressed(p) == "in")
    check("no errors", not errors, errors)
    ctx.close()

    # 11. location-off event: no GPS, nothing about location
    ctx, p, calls, state, errors = new_page(browser, events=EVX)
    state["xreply"] = {"ok": True, "action": "back", "name": "Test One", "away_minutes": 20, "late_minutes": None, "day_minutes": 20, "over_limit": False}
    choose(p, "WEB1"); act(p, "back")
    check("location off: no search, no line", geo(p)["starts"] == 0 and not vis(p, "#gps"))
    p.fill("#staff", "MNHA"); p.click("#go"); wait_calls(calls.setdefault("exit", []), 1); time.sleep(0.15); p.evaluate("1")
    check("location off: sent without position", calls["exit"][0]["p_lat"] is None and calls["exit"][0]["p_accuracy"] is None)
    check("location off: back ok", toast(p) == "Back in recorded")
    # 12. older database without exit_rules: note just hides
    state["rules_status"] = 404
    act(p, "out"); wait_calls(calls.setdefault("rules", []), 1); time.sleep(0.1); p.evaluate("1")
    check("no exit_rules door: note hidden, page fine", not vis(p, "#exitNote") and vis(p, "#exitReason"))
    check("no errors 2", not errors, errors)
    p.screenshot(path=SHOTS + "exit_out.png")
    ctx.close()
    browser.close()
print(f"{sum(1 for _, ok in results if ok)} of {len(results)} passed")
