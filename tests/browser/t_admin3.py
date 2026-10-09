import json, sys, time, tempfile, os, threading, http.server, socketserver, functools, datetime, copy
from playwright.sync_api import sync_playwright
SHOTS = tempfile.gettempdir() + os.sep  # screenshots for a human look go here, never into the repo
ROOT = sys.argv[1]; PORT = 8772
class Q(http.server.SimpleHTTPRequestHandler):
    def log_message(self,*a): pass
socketserver.TCPServer.allow_reuse_address = True
srv = socketserver.TCPServer(("127.0.0.1", PORT), functools.partial(Q, directory=ROOT))
threading.Thread(target=srv.serve_forever, daemon=True).start()
today = (datetime.datetime.utcnow() + datetime.timedelta(hours=8)).strftime("%Y-%m-%d")
A, B, C, D = [f"{c*8}-0000-0000-0000-00000000000{i}" for i, c in enumerate("abcd", 1)]
EV, SEL, W1 = "eeeeeeee-0000-0000-0000-000000000001", "5e1ec7ed-0000-0000-0000-000000000002", "11111111-0000-0000-0000-000000000001"
STAFF = [{"id":A,"staff_code":"AAAA","full_name":"Alpha Test","email":None,"staff_type":"staff","active":True},
         {"id":B,"staff_code":"BBBB","full_name":"Bravo Test","email":None,"staff_type":"staff","active":True},
         {"id":C,"staff_code":"CCCC","full_name":"Charlie Test","email":None,"staff_type":"intern_contract","active":True},
         {"id":D,"staff_code":"DDDD","full_name":"Delta Gone","email":None,"staff_type":"staff","active":False}]
def base_events(new):
    ev = [{"id":EV,"event_code":"0001","name":"Daily Test","latitude":1.234567,"longitude":2.345678,"radius_m":45,"require_qr":False,"active":True,"archived_at":None},
          {"id":SEL,"event_code":"COMM","name":"Committee","latitude":1.2,"longitude":2.3,"radius_m":30,"require_qr":False,"active":True,"archived_at":None}]
    if new:
        for e in ev: e.update(require_location=True, audience="all")
        ev[1]["audience"] = "selected"
    return ev
WINDOWS = [{"id":W1,"event_id":SEL,"label":"Meeting","weekdays":None,"start_time":"00:00:00","end_time":"23:59:00","starts_on":None,"ends_on":None,"archived_at":None,"late_after":None,"counts_as":None}]
iso = lambda hhmm: f"{today}T{hhmm}:00+08:00"
def att(i, staff, hhmm, **kw):
    r = {"id":i,"checked_in_at":iso(hhmm),"status":"present","reason":None,"distance_m":11,"gps_accuracy_m":12,"device_id":"DEV-"+staff[:8].upper()*2,"staff_id":staff,"event_id":SEL,"window_id":W1,"late_minutes":None,"not_listed":False}
    r.update(kw); return r
results = []
def check(name, cond, extra=""):
    results.append((name, bool(cond))); print(("PASS " if cond else "FAIL ") + name + (("  -> " + str(extra)) if (extra and not cond) else ""))

def run(browser, new=True, view="events", setup=None):
    ctx = browser.new_context(viewport={"width":1200,"height":1000}); page = ctx.new_page()
    db = {"events": base_events(new), "invited": [{"event_id":SEL,"staff_id":A},{"event_id":SEL,"staff_id":B}], "writes": [], "rpc": [],
          "present": [att("p1", A, "08:00"), att("p2", C, "08:05", not_listed=True, distance_m=None, gps_accuracy_m=None)]}
    if setup: setup(db)
    def handle(route):
        req = route.request; path = req.url.split(".supabase.co",1)[1]
        body = req.post_data_json if req.post_data else None
        def rows(data, status=200): return route.fulfill(status=status, headers={"Content-Range": f"0-{max(len(data)-1,0)}/{len(data)}", "Content-Type":"application/json"}, body=json.dumps(data))
        if path.startswith("/auth/v1/token"): return route.fulfill(json={"access_token":"test-token","refresh_token":"test-refresh","expires_in":3600,"user":{"email":"owner@local.test"}})
        if path.startswith("/auth/v1/"): return route.fulfill(json={})
        if "/rpc/admin_role" in path: return route.fulfill(json="owner")
        if "/rpc/set_event_staff" in path:
            if not new: return route.fulfill(status=404, json={"code":"PGRST202","message":"no such function"})
            db["rpc"].append(body); db["invited"] = [r for r in db["invited"] if r["event_id"] != body["p_event_id"]] + [{"event_id":body["p_event_id"],"staff_id":s} for s in body["p_staff_ids"]]
            return route.fulfill(json={"added":0,"removed":0,"total":len(body["p_staff_ids"])})
        if "/rpc/list_events" in path: return route.fulfill(json=[])
        if "/rpc/exit_set_return" in path:
            db["rpc"].append(body); return route.fulfill(json=db.get("xreply", {"ok": True}))
        if "/rpc/" in path: return route.fulfill(json=None)
        if path.startswith("/rest/v1/staff"): return rows(STAFF)
        if path.startswith("/rest/v1/events"):
            if req.method == "POST":
                row = dict(body, id="99999999-0000-0000-0000-000000000009", archived_at=None); db["writes"].append(("POST", body)); db["events"].append(row); return rows([row], 201)
            if req.method == "PATCH":
                eid = path.split("id=eq.")[1].split("&")[0]; row = next(e for e in db["events"] if e["id"] == eid); row.update(body); db["writes"].append(("PATCH", body)); return rows([row])
            return rows(db["events"])
        if path.startswith("/rest/v1/event_windows"): return rows(db.get("windows", WINDOWS))
        if path.startswith("/rest/v1/work_exit_log"):
            db.setdefault("xreads", []).append(path)
            if db.get("noexits"): return route.fulfill(status=404, json={"code":"PGRST205","message":"Could not find the table 'public.work_exit_log' in the schema cache"})
            return rows(db.get("exits", []))
        if path.startswith("/rest/v1/org_settings"): return rows([{"id":1,"organization_name":"Test School","max_gps_accuracy_m":30,"qr_valid_seconds":60}])
        if path.startswith("/rest/v1/event_staff"):
            return rows(db["invited"]) if new else route.fulfill(status=404, json={"code":"PGRST205","message":"Could not find the table 'public.event_staff' in the schema cache"})
        if path.startswith("/rest/v1/attendance?"):
            if not new and "not_listed" in path: return route.fulfill(status=400, json={"code":"42703","message":"column attendance.not_listed does not exist"})
            data = db["present"] if "status=eq.present" in path else []
            if not new: data = [{k: v for k, v in r.items() if k != "not_listed"} for r in data]
            return rows(data)
        return rows([])
    page.route("https://xtrgefkopnqgektrllra.supabase.co/**", handle)
    page.route("https://*.openstreetmap.org/**", lambda r: r.abort())
    errors = []; page.on("pageerror", lambda e: errors.append(str(e)))
    page.goto(f"http://127.0.0.1:{PORT}/admin.html#{view}")
    page.fill("#email", "owner@local.test"); page.fill("#password", "local-test-only"); page.click("#loginGo")
    page.wait_for_selector(f"#view-{view}:not([hidden])")
    page.wait_for_function("() => typeof state !== 'undefined' && state.settings")
    time.sleep(0.3)
    return ctx, page, db, errors
vis = lambda p, sel: p.is_visible(sel)
toast = lambda p: p.inner_text("#toast") if p.query_selector("#toast") and p.is_visible("#toast") else ""
def last_toast(p):
    for sel in ("#toast", ".toast"):
        el = p.query_selector(sel)
        if el and el.is_visible(): return el.inner_text()
    return ""


WIN_IO = WINDOWS + [
  {"id":"22222222-0000-0000-0000-000000000001","event_id":EV,"label":"Masuk","weekdays":None,"start_time":"06:30:00","end_time":"08:30:00","starts_on":None,"ends_on":None,"archived_at":None,"late_after":"07:40:00","counts_as":"in"},
  {"id":"22222222-0000-0000-0000-000000000002","event_id":EV,"label":"Pulang","weekdays":None,"start_time":"15:30:00","end_time":"18:00:00","starts_on":None,"ends_on":None,"archived_at":None,"late_after":None,"counts_as":"out"}]
X1, X2, X3 = "aaaa0001-0000-0000-0000-000000000001", "aaaa0001-0000-0000-0000-000000000002", "aaaa0001-0000-0000-0000-000000000003"
def xrow(i, staff, code, name, out, **kw):
    r = {"id":i,"event_id":EV,"staff_id":staff,"staff_code":code,"full_name":name,"out_at":iso(out),"reason":"Ke bank","going_home":False,"planned_back":"11:00:00",
         "back_at":None,"back_source":None,"back_note":None,"back_entered_by_email":None,"minutes_away":None,"late_minutes":None,"day_minutes":0,"over_limit":False,"status":"out"}
    r.update(kw); return r
EXITS = [xrow(X1, A, "AAAA", "Alpha Test", "09:00", back_at=iso("11:10"), back_source="recorded", minutes_away=130, late_minutes=10, day_minutes=130, status="back"),
         xrow(X2, B, "BBBB", "Bravo Test", "10:00", planned_back="10:30:00", status="overdue", reason="=cmd|' /C calc'!A0"),
         xrow(X3, C, "CCCC", "Charlie Test", "11:00", going_home=True, planned_back=None, minutes_away=270, day_minutes=270, over_limit=True, status="gone_home")]

def go_exits(p):
    p.evaluate("location.hash = 'log'"); p.wait_for_selector("#view-log:not([hidden])"); p.wait_for_timeout(400)
    p.select_option("#logEvent", EV); p.wait_for_timeout(500)

with sync_playwright() as pw:
    b = pw.chromium.launch()

    # ---- 1. older database: no switch, no tab
    ctx, p, db, errors = run(b)
    p.click(".item[data-code='0001'] button"); p.wait_for_timeout(300); pre = f"#ev-{EV}-"
    check("X1 old database: no 'allow stepping out' switch", p.query_selector(pre + "exit") is None)
    ctx.close()

    # ---- 2. switch in the event editor
    def s2(db):
        for e in db["events"]: e["allow_exit"] = False
        db["windows"] = WIN_IO
    ctx, p, db, errors = run(b, setup=s2)
    p.click(".item[data-code='0001'] button"); p.wait_for_timeout(300); pre = f"#ev-{EV}-"
    check("X2 switch shown, off, note hidden", vis(p, pre + "exit") and not p.is_checked(pre + "exit") and not vis(p, pre + "exitnote"))
    p.check(pre + "exit"); p.wait_for_timeout(80)
    check("X2 ticked: info note (event has in/out sessions)", vis(p, pre + "exitnote") and "4 hours" in p.inner_text(pre + "exitnote"))
    p.click(f"form:has({pre}name) button[type=submit]"); p.wait_for_timeout(400)
    w = db["writes"][-1] if db["writes"] else None
    check("X2 saved allow_exit true", w and w[0] == "PATCH" and w[1].get("allow_exit") is True, w)
    p.click(".item[data-code='COMM'] button"); p.wait_for_timeout(300); pre2 = f"#ev-{SEL}-"
    p.check(pre2 + "exit"); p.wait_for_timeout(80)
    check("X2 event without in/out sessions: warning note", "cannot be recorded" in p.inner_text(pre2 + "exitnote") and "warn" in p.get_attribute(pre2 + "exitnote", "class"))
    check("X2 no page errors", not errors, errors)
    ctx.close()

    # ---- 3. the Step-outs list
    def s3(db): db["events"][0]["allow_exit"] = True; db["windows"] = WIN_IO; db["exits"] = copy.deepcopy(EXITS)
    ctx, p, db, errors = run(b, view="log", setup=s3)
    go_exits(p)
    check("X3 tab shown with count", p.is_visible("button[data-tab='exits']") and "(3)" in p.inner_text("button[data-tab='exits']"), p.inner_text(".seg"))
    check("X3 read filtered by date and event", any(("exit_date=eq." + today) in r and ("event_id=eq." + EV) in r for r in db["xreads"]), db["xreads"][-1:])
    p.click("button[data-tab='exits']"); p.wait_for_timeout(200)
    row = lambda c: p.inner_text(f"tr[data-code='{c}']")
    check("X3 back row: times, length, late pill", all(x in row("AAAA") for x in ["09:00", "11:00", "11:10", "2 h 10 min", "back", "10 min late"]), row("AAAA"))
    check("X3 overdue row: pill and Enter return button", "overdue" in row("BBBB") and p.is_visible("tr[data-code='BBBB'] button[data-xfix]"), row("BBBB"))
    check("X3 going home row: 'Going home', over 4 hours", all(x in row("CCCC") for x in ["Going home", "went home", "over 4 hours", "4 h 30 min"]), row("CCCC"))
    check("X3 no Enter return on closed rows", not p.query_selector("tr[data-code='AAAA'] button[data-xfix]") and not p.query_selector("tr[data-code='CCCC'] button[data-xfix]"))
    check("X3 reason shown as text", "=cmd|" in row("BBBB"))
    p.screenshot(path=SHOTS + "adm_exits.png", full_page=True)
    p.set_viewport_size({"width": 390, "height": 900}); p.wait_for_timeout(200); p.screenshot(path=SHOTS + "adm_exits_phone.png", full_page=True)
    p.set_viewport_size({"width": 1200, "height": 1000}); p.wait_for_timeout(200)
    # CSV
    with p.expect_download() as dl: p.click("#logDownload")
    csv = open(dl.value.path(), encoding="utf-8-sig").read()
    check("X3 CSV: minutes, formula guarded, all rows", "\"130\"" in csv and "\"'=cmd|" in csv and csv.count("\n") == 3 and "Over 4 hours" in csv, csv[:400])
    check("X3 CSV name", dl.value.suggested_filename.endswith("_exits.csv"), dl.value.suggested_filename)
    # manual return
    p.click("tr[data-code='BBBB'] button[data-xfix]"); p.wait_for_timeout(200)
    check("X4 form open for Bravo", p.is_visible("#xfixBox") and "BBBB" in p.inner_text("#xfixBox"))
    p.fill("#xfixReason", "ok"); p.fill("#xfixTime", "10:45"); p.click("#xfixBox button[type=submit]"); p.wait_for_timeout(200)
    check("X4 short reason refused on the page", not db["rpc"])
    db["xreply"] = {"ok": False, "reason": "before_out"}
    p.fill("#xfixReason", "Lupa tekan butang"); p.click("#xfixBox button[type=submit]"); p.wait_for_timeout(400)
    check("X4 refusal explained", "before they went out" in last_toast(p) and p.is_visible("#xfixBox"), last_toast(p))
    db["xreply"] = {"ok": True}
    p.click("#xfixBox button[type=submit]"); p.wait_for_timeout(500)
    sent = db["rpc"][-1]
    check("X4 sent exit_set_return with time and reason", sent == {"p_exit_id": X2, "p_time": "10:45", "p_reason": "Lupa tekan butang", "p_went_home": False}, sent)
    check("X4 form closed after save", not p.query_selector("#xfixBox"))
    p.click("tr[data-code='BBBB'] button[data-xfix]"); p.wait_for_timeout(200)
    p.select_option("#xfixWhat", "home"); p.wait_for_timeout(50)
    check("X4 'did not come back' hides the time", not p.is_visible("#xfixTime"))
    p.fill("#xfixReason", "Tidak kembali, maklum kerani"); p.click("#xfixBox button[type=submit]"); p.wait_for_timeout(500)
    sent = db["rpc"][-1]
    check("X4 sent went home without time", sent["p_went_home"] is True and sent["p_time"] is None, sent)
    # BM words
    p.click(".lang button[data-lang='ms']") if p.query_selector(".lang button[data-lang='ms']") else p.evaluate("state.lang='ms'; drawLanguage()")
    p.wait_for_timeout(200)
    check("X5 BM tab name", "Keluar (3)" in p.inner_text(".seg"), p.inner_text(".seg"))
    check("X5 no page errors", not errors, errors)
    # sign out empties the list
    p.evaluate("endSession()"); p.wait_for_timeout(100)
    check("X6 sign-out empties step-outs", p.evaluate("state.log.exits.length") == 0)
    ctx.close()

    # ---- 7. operator: list but no button
    def s3(db): db["events"][0]["allow_exit"] = True; db["windows"] = WIN_IO; db["exits"] = copy.deepcopy(EXITS)
    ctx, p, db, errors = run(b, view="log", setup=s3)
    p.evaluate("state.role = 'operator'"); go_exits(p); p.click("button[data-tab='exits']"); p.wait_for_timeout(200)
    check("X7 operator: no Enter return button", p.is_visible("tr[data-code='BBBB']") and not p.query_selector("button[data-xfix]"))
    ctx.close()

    # ---- 8. database without file 13: no tab, asks once
    ctx, p, db, errors = run(b, view="log", setup=lambda db: db.update(noexits=True))
    go_exits(p); n = len(db.get("xreads", []))
    p.click("#logRefresh"); p.wait_for_timeout(400)
    check("X8 no view: no tab, no error card, stops asking", not p.query_selector("button[data-tab='exits']") and not p.query_selector("#logError") and len(db.get("xreads", [])) == n, (n, len(db.get("xreads", []))))
    check("X8 no page errors", not errors, errors)
    ctx.close()
    b.close()
print(f"{sum(1 for _, ok in results if ok)} of {len(results)} passed")
