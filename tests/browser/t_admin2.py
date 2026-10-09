import json, sys, time, threading, http.server, socketserver, functools, datetime, copy
from playwright.sync_api import sync_playwright
ROOT = sys.argv[1]; PORT = 8769
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

def run(browser, new=True, view="events"):
    ctx = browser.new_context(viewport={"width":1200,"height":1000}); page = ctx.new_page()
    db = {"events": base_events(new), "invited": [{"event_id":SEL,"staff_id":A},{"event_id":SEL,"staff_id":B}], "writes": [], "rpc": [],
          "present": [att("p1", A, "08:00"), att("p2", C, "08:05", not_listed=True, distance_m=None, gps_accuracy_m=None)]}
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
        if "/rpc/" in path: return route.fulfill(json=None)
        if path.startswith("/rest/v1/staff"): return rows(STAFF)
        if path.startswith("/rest/v1/events"):
            if req.method == "POST":
                row = dict(body, id="99999999-0000-0000-0000-000000000009", archived_at=None); db["writes"].append(("POST", body)); db["events"].append(row); return rows([row], 201)
            if req.method == "PATCH":
                eid = path.split("id=eq.")[1].split("&")[0]; row = next(e for e in db["events"] if e["id"] == eid); row.update(body); db["writes"].append(("PATCH", body)); return rows([row])
            return rows(db["events"])
        if path.startswith("/rest/v1/event_windows"): return rows(WINDOWS)
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

with sync_playwright() as pw:
    b = pw.chromium.launch()

    # ---- new event, location off
    ctx, p, db, errors = run(b); p.click("#evAdd"); p.wait_for_timeout(200); pre = "#ev-new-"
    check("E1 new event: Require location is ON, place box shown, no notes", p.is_checked(pre+"loc") and vis(p, pre+"locbox") and not vis(p, pre+"locoff") and not vis(p, pre+"open") and not vis(p, pre+"invbox"), "")
    p.uncheck(pre+"loc"); p.wait_for_timeout(100)
    check("E1 switched off: map and numbers hidden, note explains, both-off warning shown", not vis(p, pre+"locbox") and not vis(p, pre+"lat") and vis(p, pre+"locoff") and vis(p, pre+"open"), "")
    p.check(pre+"qr"); p.wait_for_timeout(50)
    check("E1 QR switched on: the both-off warning goes away", not vis(p, pre+"open") and vis(p, pre+"locoff"), "")
    p.uncheck(pre+"qr"); p.fill(pre+"name", "Online Briefing"); p.fill(pre+"code", "web1"); p.click(pre.replace("#","form:has(#") + "name) button[type=submit]"); p.wait_for_timeout(400)
    w = db["writes"][-1] if db["writes"] else None
    check("E2 saved without a pin: location off, no coordinates, all staff, no list sent", w and w[0] == "POST" and w[1]["require_location"] is False and w[1]["latitude"] is None and w[1]["longitude"] is None and w[1]["radius_m"] is None and w[1]["audience"] == "all" and w[1]["event_code"] == "WEB1" and not db["rpc"], w)
    check("E2 list shows 'no location' for it", "WEB1 · no location" in p.inner_text("#evRows"), p.inner_text("#evRows")[:200])
    check("E2 no page errors", not errors, errors); ctx.close()

    # ---- existing event: switch off keeps the pin; switch on needs one
    ctx, p, db, errors = run(b); p.click(".item[data-code='0001'] button"); p.wait_for_timeout(300); pre = f"#ev-{EV}-"
    p.uncheck(pre+"loc"); p.wait_for_timeout(100); p.click(f"form:has({pre}name) button[type=submit]"); p.wait_for_timeout(400)
    w = db["writes"][-1] if db["writes"] else None
    check("E3 existing event switched off: pin and radius kept in the database", w and w[0] == "PATCH" and w[1]["require_location"] is False and w[1]["latitude"] == 1.234567 and w[1]["longitude"] == 2.345678 and w[1]["radius_m"] == 45, w)
    p.click(".item[data-code='0001'] button"); p.wait_for_timeout(300)
    check("E3 reopened: switch is off, place box hidden", not p.is_checked(pre+"loc") and not vis(p, pre+"locbox"), "")
    p.check(pre+"loc"); p.wait_for_timeout(200)
    check("E3 switched back on: the old pin is there again", vis(p, pre+"locbox") and p.input_value(pre+"lat") == "1.234567" and p.input_value(pre+"rad") == "45", (p.input_value(pre+"lat"), p.input_value(pre+"rad")))
    p.fill(pre+"lat", ""); n = len(db["writes"]); p.click(f"form:has({pre}name) button[type=submit]"); p.wait_for_timeout(300)
    check("E3 location on without a pin: refused by the page, nothing sent", len(db["writes"]) == n, db["writes"][n:]); ctx.close()

    # ---- selected staff
    ctx, p, db, errors = run(b)
    check("E4 event list: pill 'Selected staff: 2'", "Selected staff: 2" in p.inner_text(".item[data-code='COMM']"), p.inner_text(".item[data-code='COMM']"))
    p.click(".item[data-code='COMM'] button"); p.wait_for_timeout(300); pre = f"#ev-{SEL}-"
    ticks = lambda: p.evaluate(f"[...document.querySelectorAll('{pre}invlist input')].map(i => [i.value, i.checked])")
    check("E4 picker shown with the saved list ticked; inactive staff not offered", vis(p, pre+"invbox") and p.input_value(pre+"aud") == "selected" and dict(ticks()) == {A: True, B: True, C: False} and "2 selected" in p.inner_text(pre+"invn"), ticks())
    p.fill(pre+"invq", "char"); p.wait_for_timeout(100)
    check("E4 search narrows the list", [t[0] for t in ticks()] == [C], ticks())
    p.click(pre+"invall"); p.wait_for_timeout(50); p.fill(pre+"invq", ""); p.wait_for_timeout(50); p.select_option(pre+"invt", "staff"); p.wait_for_timeout(100)
    check("E4 'Select all shown' ticked Charlie; type filter shows staff only; count 3", [t[0] for t in ticks()] == [A, B] and "3 selected" in p.inner_text(pre+"invn"), (ticks(), p.inner_text(pre+"invn")))
    p.click(pre+"invnone"); p.wait_for_timeout(50)
    check("E4 'Clear all shown' unticks only what is shown", "1 selected" in p.inner_text(pre+"invn"), p.inner_text(pre+"invn"))
    p.select_option(pre+"invt", "all"); p.wait_for_timeout(50); p.click(f"{pre}invlist input[value='{A}']"); p.wait_for_timeout(50)
    p.click(f"form:has({pre}name) button[type=submit]"); p.wait_for_timeout(500)
    r = db["rpc"][-1] if db["rpc"] else None
    check("E4 save: event saved as 'selected', then ONE call swaps the list to Alpha + Charlie", r and r["p_event_id"] == SEL and sorted(r["p_staff_ids"]) == sorted([A, C]) and db["writes"][-1][1]["audience"] == "selected", (r, db["writes"][-1:]))
    check("E4 list pill follows", "Selected staff: 2" in p.inner_text(".item[data-code='COMM']"), p.inner_text(".item[data-code='COMM']"))
    p.click(".item[data-code='COMM'] button"); p.wait_for_timeout(300); p.click(pre+"invall"); p.click(pre+"invnone"); p.wait_for_timeout(50); n = len(db["rpc"])
    p.click(f"form:has({pre}name) button[type=submit]"); p.wait_for_timeout(300)
    check("E4 selected with nobody ticked: refused by the page", len(db["rpc"]) == n and vis(p, pre+"invbox"), "")
    p.select_option(pre+"aud", "all"); p.wait_for_timeout(50); nw = len(db["writes"])
    check("E4 set to All staff: picker hidden", not vis(p, pre+"invbox"), "")
    p.click(f"form:has({pre}name) button[type=submit]"); p.wait_for_timeout(400)
    check("E4 saved as All staff: no list call, old list left alone", len(db["rpc"]) == n and len(db["writes"]) == nw + 1 and db["writes"][-1][1]["audience"] == "all", (db["rpc"][n:], db["writes"][nw:]))
    check("E4 no page errors", not errors, errors); ctx.close()

    # ---- attendance for a selected-staff event
    ctx, p, db, errors = run(b, view="log"); p.wait_for_function("() => !document.querySelector('#view-log .skeleton')")
    p.select_option("#logEvent", SEL); p.wait_for_function("() => !document.querySelector('#view-log .skeleton')"); p.wait_for_timeout(200)
    lab = lambda tab: p.inner_text(f"#view-log .seg button[data-tab='{tab}']")
    tbl = lambda: p.evaluate("[...document.querySelectorAll('#view-log tbody tr')].map(tr => [...tr.cells].map(td => td.textContent.trim()))")
    head = lambda: p.evaluate("[...document.querySelectorAll('#view-log thead th')].map(th => th.textContent.trim())")
    rows = tbl()
    li = head().index("List") if "List" in head() else -1
    check("E5 present: 2 rows, a 'List' column, Charlie marked 'Not on the list', Alpha not marked", "(2)" in lab("present") and li >= 0 and rows[0][li] == "" and "AAAA" in rows[0] and rows[1][li] == "Not on the list" and "CCCC" in rows[1], (head(), rows))
    p.check("#logDetails"); p.wait_for_timeout(150); rows = tbl(); di = head().index("Distance")
    check("E5 details: a check-in without a position shows blank distance and accuracy, others unchanged", rows[0][di] == "11 m" and rows[1][di] == "" and rows[1][di + 1] == "", rows)
    p.click("#view-log .seg button[data-tab='absent']"); p.wait_for_timeout(100); rows = tbl()
    check("E5 not checked in: only the invited who have not come (Bravo), not all staff", "(1)" in lab("absent") and len(rows) == 1 and "BBBB" in rows[0], (lab("absent"), rows))
    p.select_option("#logEvent", EV); p.wait_for_function("() => !document.querySelector('#view-log .skeleton')"); p.wait_for_timeout(200)
    check("E5 an all-staff event still lists every active staff member as not checked in", "(3)" in lab("absent"), lab("absent"))
    p.click(".lang button[data-lang='ms']"); p.wait_for_timeout(300); p.wait_for_function("() => !document.querySelector('#view-log .skeleton')")
    p.select_option("#logEvent", SEL); p.wait_for_function("() => !document.querySelector('#view-log .skeleton')"); p.click("#view-log .seg button[data-tab='present']"); p.wait_for_timeout(200)
    check("E5 Bahasa Melayu: 'Tiada dalam senarai'", any("Tiada dalam senarai" in c for r in tbl() for c in r), tbl())
    same = p.evaluate("(() => { const k = o => Object.keys(o).sort().join(); return k(TEXT.ms) === k(TEXT.en); })()")
    check("words: BM and EN have identical keys", same)
    check("E5 no page errors", not errors, errors); ctx.close()

    # ---- older database (SQL file 12 not run)
    ctx, p, db, errors = run(b, new=False); p.click("#evAdd"); p.wait_for_timeout(200); pre = "#ev-new-"
    check("F1 older database: neither new choice is shown; the form is the old one", not p.query_selector(pre+"loc") and not p.query_selector(pre+"aud") and not p.query_selector(pre+"invbox") and vis(p, pre+"lat"), "")
    p.fill(pre+"name", "Old style"); p.fill(pre+"code", "OLD1"); p.fill(pre+"lat", "1.5"); p.fill(pre+"lng", "2.5"); p.click(f"form:has({pre}name) button[type=submit]"); p.wait_for_timeout(400)
    w = db["writes"][-1] if db["writes"] else None
    check("F1 saving sends only the old fields", w and w[0] == "POST" and "require_location" not in w[1] and "audience" not in w[1] and w[1]["latitude"] == 1.5 and w[1]["radius_m"] == 50, w)
    check("F1 no page errors", not errors, errors); ctx.close()
    ctx, p, db, errors = run(b, new=False, view="log"); p.wait_for_function("() => !document.querySelector('#view-log .skeleton')")
    p.select_option("#logEvent", SEL); p.wait_for_function("() => !document.querySelector('#view-log .skeleton')"); p.wait_for_timeout(200)
    check("F2 older database: attendance still loads (2 present), no 'List' column, no error card", "(2)" in p.inner_text("#view-log .seg button[data-tab='present']") and "List" not in p.evaluate("[...document.querySelectorAll('#view-log thead th')].map(th => th.textContent.trim())") and not p.query_selector("#logError") and not errors, errors); ctx.close()
    b.close()
bad = [n for n, ok in results if not ok]
print(f"\n{len(results) - len(bad)} of {len(results)} passed"); sys.exit(1 if bad else 0)
