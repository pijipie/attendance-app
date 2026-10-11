import json, sys, time, threading, http.server, socketserver, functools, re, datetime
from playwright.sync_api import sync_playwright
ROOT = sys.argv[1]; PORT = 8766
class Q(http.server.SimpleHTTPRequestHandler):
    def log_message(self,*a): pass
socketserver.TCPServer.allow_reuse_address = True
srv = socketserver.TCPServer(("127.0.0.1", PORT), functools.partial(Q, directory=ROOT))
threading.Thread(target=srv.serve_forever, daemon=True).start()
today = (datetime.datetime.utcnow() + datetime.timedelta(hours=8)).strftime("%Y-%m-%d")
A, B, C = "aaaaaaaa-0000-0000-0000-000000000001", "bbbbbbbb-0000-0000-0000-000000000002", "cccccccc-0000-0000-0000-000000000003"
EV, W1, W2 = "eeeeeeee-0000-0000-0000-000000000001", "11111111-0000-0000-0000-000000000001", "22222222-0000-0000-0000-000000000002"
STAFF = [{"id":A,"staff_code":"AAAA","full_name":"Alpha Test","email":None,"staff_type":"staff","active":True},
         {"id":B,"staff_code":"BBBB","full_name":"Bravo Test","email":None,"staff_type":"staff","active":True},
         {"id":C,"staff_code":"CCCC","full_name":"Charlie Test","email":None,"staff_type":"staff","active":True}]
EVENTS = [{"id":EV,"event_code":"0001","name":"Daily Test","latitude":1.0,"longitude":2.0,"radius_m":45,"require_qr":False,"active":True,"archived_at":None}]
WINDOWS = [{"id":W1,"event_id":EV,"label":"Pagi","weekdays":None,"start_time":"04:00:00","end_time":"15:30:00","starts_on":None,"ends_on":None,"archived_at":None,"late_after":"07:40:00","counts_as":None},
           {"id":W2,"event_id":EV,"label":"Petang","weekdays":None,"start_time":"15:30:00","end_time":"23:59:00","starts_on":None,"ends_on":None,"archived_at":None,"late_after":None,"counts_as":None}]
iso = lambda hhmm: f"{today}T{hhmm}:00+08:00"
PRESENT  = [{"id":"p1","checked_in_at":iso("06:54"),"status":"present","reason":None,"distance_m":11,"gps_accuracy_m":17,"device_id":"DEV-AAAAAAAAAAAAAAAA","staff_id":A,"event_id":EV,"window_id":W1,"late_minutes":None}]
REJECTED = [{"id":"r1","checked_in_at":iso("07:39"),"status":"rejected","reason":"outside_geofence","distance_m":75,"gps_accuracy_m":9,"device_id":"DEV-BBBBBBBBBBBBBBBB","staff_id":B,"event_id":EV,"window_id":W1,"late_minutes":None}]
STUCK    = [{"id":1,"at":iso("07:30"),"kind":"denied","device_id":"DEV-CCCCCCCCCCCCCCCC","staff_id":C,"event_id":EV},
            {"id":2,"at":iso("08:12"),"kind":"timeout","device_id":"DEV-BBBBBBBBBBBBBBBB","staff_id":B,"event_id":EV}]
results = []
def check(name, cond, extra=""):
    results.append((name, bool(cond))); print(("PASS " if cond else "FAIL ") + name + (("  -> " + str(extra)) if (extra and not cond) else ""))

def run(browser, problems):          # problems: "rows" | "missing" | "broken"
    ctx = browser.new_context(viewport={"width":1200,"height":900}, accept_downloads=True); page = ctx.new_page(); seen = []
    def handle(route):
        url = route.request.url; path = url.split(".supabase.co",1)[1]; seen.append(path)
        def rows(data): return route.fulfill(status=200, headers={"Content-Range": f"0-{max(len(data)-1,0)}/{len(data)}", "Content-Type":"application/json"}, body=json.dumps(data))
        if path.startswith("/auth/v1/token"): return route.fulfill(json={"access_token":"test-token","refresh_token":"test-refresh","expires_in":3600,"user":{"email":"owner@local.test"}})
        if path.startswith("/auth/v1/"): return route.fulfill(json={})
        if "/rpc/admin_role" in path: return route.fulfill(json="owner")
        if "/rpc/list_events" in path: return route.fulfill(json=[])
        if "/rpc/" in path: return route.fulfill(json=None)
        if path.startswith("/rest/v1/staff"): return rows(STAFF)
        if path.startswith("/rest/v1/events"): return rows(EVENTS)
        if path.startswith("/rest/v1/event_windows"): return rows(WINDOWS)
        if path.startswith("/rest/v1/org_settings"): return rows([{"id":1,"organization_name":"Test School","max_gps_accuracy_m":30,"qr_valid_seconds":60}])
        if path.startswith("/rest/v1/attendance?"): return rows(PRESENT if "status=eq.present" in path else REJECTED)
        if path.startswith("/rest/v1/location_problems"):
            if problems == "missing": return route.fulfill(status=404, json={"code":"PGRST205","message":"Could not find the table 'public.location_problems' in the schema cache"})
            if problems == "broken":  return route.fulfill(status=500, json={"code":"XX000","message":"boom"})
            return rows(STUCK)
        return rows([])
    page.route("https://xtrgefkopnqgektrllra.supabase.co/**", handle)
    page.route("https://*.openstreetmap.org/**", lambda r: r.abort())
    errors = []; page.on("pageerror", lambda e: errors.append(str(e)))
    page.goto(f"http://127.0.0.1:{PORT}/admin.html#log")
    page.fill("#email", "owner@local.test"); page.fill("#password", "local-test-only"); page.click("#loginGo")
    page.wait_for_selector("#view-log:not([hidden]) .seg button[data-tab='rejected']")
    page.wait_for_function("() => !document.querySelector('#view-log .skeleton')")
    return ctx, page, seen, errors
label = lambda p, tab: p.inner_text(f"#view-log .seg button[data-tab='{tab}']")
def table(p): return p.evaluate("[...document.querySelectorAll('#view-log tbody tr')].map(tr => [...tr.cells].map(td => td.textContent.trim()))")

with sync_playwright() as pw:
    b = pw.chromium.launch()
    ctx, p, seen, errors = run(b, "rows")
    check("A1 counts: Present (1), Rejected (3) = 1 from the database + 2 from devices", "(1)" in label(p,"present") and "(3)" in label(p,"rejected"), (label(p,"present"), label(p,"rejected")))
    p.click("#view-log .seg button[data-tab='rejected']"); rows = table(p)
    times = [r[0][:5] for r in rows]
    check("A2 Rejected list in time order 07:30, 07:39, 08:12", times == ["07:30","07:39","08:12"], rows)
    flat = [" | ".join(r) for r in rows]
    check("A3 device rows named and explained", "CCCC" in flat[0] and "Device: location blocked" in flat[0] and "Device: GPS did not answer" in flat[2] and "BBBB" in flat[2], flat)
    check("A4 database row unchanged", "Outside the area" in flat[1] and "BBBB" in flat[1], flat[1])
    p.check("#logDetails") if p.query_selector("#logDetails") else None; time.sleep(0.1); rows = table(p)
    check("A5 details on: no crash, device row shows its device, blank distance/accuracy", len(rows) == 3 and any("CCCCCCCC" in c for c in rows[0]) and not errors, (rows, errors))
    # a session filter keeps device rows (they have no session)
    p.select_option("#logEvent", EV); p.wait_for_function("() => !document.querySelector('#view-log .skeleton')")
    if p.query_selector("#logSession"):
        p.select_option("#logSession", W2); time.sleep(0.1); p.click("#view-log .seg button[data-tab='rejected']"); time.sleep(0.1); rows = table(p)
        check("A6 session 'Petang' chosen: database row (Pagi) hidden, the 2 device rows stay", len(rows) == 2 and all("Device:" in " ".join(r) for r in rows), rows)
    else: check("A6 session filter present", False)
    check("A7 event filter passed to the database for the new table", any("location_problems" in s and "event_id=eq." + EV in s and "problem_date=eq." + today in s for s in seen), [s for s in seen if "location_problems" in s])
    with p.expect_download() as d: p.click("#logDownload")
    csv = open(d.value.path(), encoding="utf-8-sig").read()
    check("A8 CSV download contains the device rows", "Device: location blocked" in csv and "Device: GPS did not answer" in csv, csv[:400])
    p.click(".lang button[data-lang='ms']"); time.sleep(0.3); p.wait_for_function("() => !document.querySelector('#view-log .skeleton') && document.querySelectorAll('#view-log tbody tr').length > 0"); rows = table(p)
    check("A9 Bahasa Melayu words", any("Peranti: lokasi disekat" in c for c in rows[0]) and any("Peranti: GPS tidak menjawab" in c for c in rows[-1]), rows)
    check("A10 no page errors", not errors, errors); ctx.close()

    ctx, p, seen, errors = run(b, "missing")
    check("B1 older database (no table): list loads as before, Rejected (1), no error card", "(1)" in label(p,"rejected") and "(1)" in label(p,"present") and not p.query_selector("#logError") and not errors, (label(p,"rejected"), errors))
    n = sum("location_problems" in s for s in seen); p.click("#logRefresh"); p.wait_for_function("() => !document.querySelector('#view-log .skeleton')"); time.sleep(0.2)
    check("B2 and the page stops asking for the missing table", sum("location_problems" in s for s in seen) == n == 1, (n, sum("location_problems" in s for s in seen))); ctx.close()

    ctx, p, seen, errors = run(b, "broken")
    check("C1 a real failure of the new table is shown as a failure, not as an empty list", p.query_selector("#logError") is not None, label(p,"rejected")); ctx.close()
    b.close()
bad = [n for n, ok in results if not ok]
print(f"\n{len(results) - len(bad)} of {len(results)} passed"); sys.exit(1 if bad else 0)
