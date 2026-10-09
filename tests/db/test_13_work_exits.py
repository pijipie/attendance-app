import subprocess, json, sys, datetime
import os, shlex
# The scratch database made by tests/db/setup.sh. Override with PSQL="psql -h ... -p ... -d ..." if yours differs.
PSQL = shlex.split(os.environ.get("PSQL", "runuser -u postgres -- psql -h /var/tmp/pgtest -p 54329 -d t")) + ["-X","-At","-q","-v","ON_ERROR_STOP=1"]
def q(sql, role=None, uid=None):
    pre = ""
    if role: pre = "begin; set local role %s; " % role + ("set local request.jwt.claim.sub = '%s'; " % uid if uid else "")
    post = "; commit;" if role else ""
    r = subprocess.run(PSQL, input=pre + sql + post, capture_output=True, text=True)
    if r.returncode: return "ERR " + r.stderr.strip().replace("\n"," / ")
    return r.stdout.strip()
fails = 0; n = 0
def check(name, got, want):
    global fails, n; n += 1
    ok = want(got) if callable(want) else got == want
    if not ok: fails += 1
    print(("PASS " if ok else "FAIL ") + name + ("" if ok else "   got: %r" % (got,)))
def j(s): 
    try: return json.loads(s)
    except Exception: return {"raw": s}

now = datetime.datetime.strptime(q("select to_char(now() at time zone 'Asia/Kuala_Lumpur','HH24:MI')"), "%H:%M")
T = lambda m: (now + datetime.timedelta(minutes=m)).strftime("%H:%M")
assert 3 <= now.hour <= 17, "run between 03:00 and 17:59 KL"
q(f"""
insert into staff (id, staff_code, full_name) values
 ('00000000-0000-0000-0000-00000000000a','T001','Alpha'),
 ('00000000-0000-0000-0000-00000000000b','T002','Bravo'),
 ('00000000-0000-0000-0000-00000000000c','T003','Charlie');
insert into events (id, event_code, name, latitude, longitude, radius_m, require_qr, allow_exit) values
 ('00000000-0000-0000-0000-0000000000e1','HARIAN','Daily',1.5,101.0,100,false,true),
 ('00000000-0000-0000-0000-0000000000e2','MEET','Meeting',1.5,101.0,100,false,false),
 ('00000000-0000-0000-0000-0000000000e3','NOSESS','No sessions',1.5,101.0,100,false,true);
insert into events (id, event_code, name, require_qr, allow_exit, require_location) values
 ('00000000-0000-0000-0000-0000000000e4','NOLOC','No location',false,true,false);
insert into event_windows (id, event_id, label, start_time, end_time, late_after, counts_as) values
 ('00000000-0000-0000-0000-0000000000f1','00000000-0000-0000-0000-0000000000e1','Masuk','{T(-180)}','{T(-60)}','{T(-120)}','in'),
 ('00000000-0000-0000-0000-0000000000f2','00000000-0000-0000-0000-0000000000e1','Pulang','{T(300)}','{T(360)}',null,'out'),
 ('00000000-0000-0000-0000-0000000000f3','00000000-0000-0000-0000-0000000000e4','Masuk','{T(-180)}','{T(-60)}','{T(-120)}','in'),
 ('00000000-0000-0000-0000-0000000000f4','00000000-0000-0000-0000-0000000000e4','Pulang','{T(300)}','{T(360)}',null,'out');
insert into attendance (staff_id, event_id, window_id, checked_in_at, device_id, status) values
 ('00000000-0000-0000-0000-00000000000a','00000000-0000-0000-0000-0000000000e1','00000000-0000-0000-0000-0000000000f1', now() - interval '150 minutes','devA','present'),
 ('00000000-0000-0000-0000-00000000000b','00000000-0000-0000-0000-0000000000e1','00000000-0000-0000-0000-0000000000f1', now() - interval '150 minutes','devB','present'),
 ('00000000-0000-0000-0000-00000000000c','00000000-0000-0000-0000-0000000000e1','00000000-0000-0000-0000-0000000000f1', now() - interval '150 minutes','devC','rejected'),
 ('00000000-0000-0000-0000-00000000000c','00000000-0000-0000-0000-0000000000e4','00000000-0000-0000-0000-0000000000f3', now() - interval '150 minutes','devC','present');
insert into auth.users (id, email, email_confirmed_at) values
 ('00000000-0000-0000-0000-0000000000a1','mgr@x.test', now()), ('00000000-0000-0000-0000-0000000000a2','op@x.test', now()),
 ('00000000-0000-0000-0000-0000000000a3','nobody@x.test', now());
insert into admins (user_id, role) values ('00000000-0000-0000-0000-0000000000a1','owner'), ('00000000-0000-0000-0000-0000000000a2','operator');
""")
HERE = "1.5, 101.0, 10"
def wx(action, staff, event="HARIAN", pos=HERE, dev="devA", reason=None, back=None, home=False, role="anon"):
    r = "null" if reason is None else "'%s'" % reason.replace("'", "''")
    b = "null" if back is None else "'%s'" % back
    return j(q(f"select work_exit('{action}','{staff}','{event}',{pos},'{dev}',{r},{b},{str(home).lower()})", role=role))

r = j(q("select exit_rules('HARIAN')", role="anon"))
check("rules: hours and limit", r, {"ok": True, "limit_minutes": 240, "work_start": T(-120), "work_end": T(300), "now": T(0), "open_now": True, "latest": T(240)})
check("rules: event without outings", j(q("select exit_rules('MEET')", role="anon")), {"ok": False})
check("rules: no sessions -> ok false", j(q("select exit_rules('NOSESS')", role="anon")).get("ok"), False)
check("not allowed event", wx("out","T001","MEET",reason="Bank",back=T(30)).get("reason"), "exit_not_allowed")
check("location required", wx("out","T001",pos="null,null,null",reason="Bank",back=T(30)).get("reason"), "location_required")
check("accuracy too low", wx("out","T001",pos="1.5,101.0,80",reason="Bank",back=T(30)).get("reason"), "gps_accuracy_too_low")
r = wx("out","T001",pos="1.51,101.0,10",reason="Bank",back=T(30))
check("outside geofence with distance", (r.get("reason"), r.get("distance_m",0) > 1000), ("outside_geofence", True))
check("no sessions -> outside_work_hours", wx("out","T001","NOSESS",reason="Bank",back=T(30)).get("reason"), "outside_work_hours")
check("unknown staff", wx("out","ZZZ9",reason="Bank",back=T(30)), {"ok": False, "reason": "unknown_staff_or_event"})
check("rejected check-in is not a check-in", wx("out","T003",dev="devC",reason="Bank",back=T(30)).get("reason"), "not_checked_in")
check("reason needed", wx("out","T001",back=T(30)).get("reason"), "reason_needed")
check("reason 1 char", wx("out","T001",reason=" x ",back=T(30)).get("reason"), "reason_needed")
check("reason too long", wx("out","T001",reason="a"*250,back=T(30)).get("reason"), "reason_too_long")
check("reason oversize input", wx("out","T001",reason="a"*500,back=T(30)).get("reason"), "bad_input")
check("bad time shape", wx("out","T001",reason="Bank",back="25:00").get("reason"), "bad_input")
check("time needed + latest", wx("out","T001",reason="Bank"), {"ok": False, "reason": "time_needed", "latest": T(240)})
check("time in past", wx("out","T001",reason="Bank",back=T(0)).get("reason"), "time_in_past")
r = wx("out","T001",reason="Bank",back=T(241))
check("return too late", (r.get("reason"), r.get("latest"), r.get("minutes_left")), ("return_too_late", T(240), 240))
check("nothing stored so far", q("select count(*) from work_exits"), "0")
r = wx("out","T001",reason="Ke bank (urusan)",back=T(240))
check("out ok at the limit", r, {"ok": True, "action": "out", "going_home": False, "name": "Alpha", "back_by": T(240)})
check("already out", wx("out","T001",reason="Bank",back=T(30)), {"ok": False, "reason": "already_out", "back_by": T(240)})
check("device used by another", wx("out","T002",dev="devA",reason="Klinik",back=T(30)).get("reason"), "device_already_used")
check("back without outing", wx("back","T002",dev="devB").get("reason"), "no_open_exit")
r = wx("back","T001")
check("back ok", (r.get("ok"), r.get("away_minutes"), r.get("late_minutes"), r.get("day_minutes"), r.get("over_limit")), (True, 0, None, 0, False))
# an earlier outing of 200 minutes today
q("""insert into work_exits (staff_id,event_id,exit_date,out_at,reason,planned_back,back_at,back_source,out_device)
     values ('00000000-0000-0000-0000-00000000000a','00000000-0000-0000-0000-0000000000e1',(now() at time zone 'Asia/Kuala_Lumpur')::date,
             now() - interval '210 minutes','Earlier', ((now() - interval '20 minutes') at time zone 'Asia/Kuala_Lumpur')::time, now() - interval '10 minutes','recorded','devA')""")
check("latest shrinks after 200 used", wx("out","T001",reason="Bank").get("latest"), T(40))
check("return too late, 40 left", wx("out","T001",reason="Bank",back=T(45)).get("minutes_left"), 40)
r = wx("out","T001",reason="Anak sakit",home=True)
check("going home always accepted, over 4 h", (r.get("ok"), r.get("going_home"), r.get("over_limit")), (True, True, True))
check("back after going home", wx("back","T001").get("reason"), "already_gone_home")
check("out after going home", wx("out","T001",reason="x y",back=T(10)).get("reason"), "already_gone_home")
# staff B: goes out with planned back already passed -> overdue
r = wx("out","T002",dev="devB",reason="Pos laju",back=T(20))
check("B out ok", r.get("ok"), True)
q("update work_exits set out_at = now() - interval '60 minutes', planned_back = date_trunc('minute', (now() - interval '30 minutes') at time zone 'Asia/Kuala_Lumpur')::time where staff_id = '00000000-0000-0000-0000-00000000000b'")
log = q("select staff_code||'|'||status||'|'||coalesce(minutes_away::text,'-')||'|'||day_minutes||'|'||over_limit from work_exit_log order by staff_code, out_at")
check("log rows", log.splitlines(), ["T001|back|200|500|true", "T001|back|0|500|true", "T001|gone_home|300|500|true", "T002|overdue|-|0|false"])
wh = q("select out_source from work_hours where staff_id='00000000-0000-0000-0000-00000000000a'") 
check("work_hours: going home is the check-out", wh, "exit")
# admin manual return
bid = q("select id from work_exits where staff_id='00000000-0000-0000-0000-00000000000b'")
check("set_return: not admin", q(f"select exit_set_return('{bid}','{T(-5)}','Lupa tekan')", "authenticated", "00000000-0000-0000-0000-0000000000a3"), lambda s: "not_allowed" in s)
check("set_return: operator", q(f"select exit_set_return('{bid}','{T(-5)}','Lupa tekan')", "authenticated", "00000000-0000-0000-0000-0000000000a2"), lambda s: "not_allowed" in s)
check("set_return: anon cannot call", q(f"select exit_set_return('{bid}','{T(-5)}','Lupa tekan')", "anon"), lambda s: "permission denied" in s)
M = ("authenticated", "00000000-0000-0000-0000-0000000000a1")
check("set_return: before out", j(q(f"select exit_set_return('{bid}','{T(-70)}','Lupa tekan')", *M)).get("reason"), "before_out")
check("set_return: future", j(q(f"select exit_set_return('{bid}','{T(5)}','Lupa tekan')", *M)).get("reason"), "in_future")
check("set_return: short reason", j(q(f"select exit_set_return('{bid}','{T(-5)}','ok')", *M)).get("reason"), "bad_input")
check("set_return: ok", j(q(f"select exit_set_return('{bid}','{T(-5)}','Lupa tekan butang')", *M)), {"ok": True})
check("set_return: again -> not_open", j(q(f"select exit_set_return('{bid}','{T(-5)}','Lupa tekan butang')", *M)).get("reason"), "not_open")
check("log after manual", q("select status||'|'||minutes_away||'|'||late_minutes||'|'||back_source||'|'||back_entered_by_email from work_exit_log where staff_code='T002'"), "back|55|25|manual|mgr@x.test")
check("audit line", q("select target||'|'||summary||'|'||(detail->'back'->>1) from admin_audit where target='work_exits'"), lambda s: s.startswith("work_exits|T002 ") and s.endswith("|"+T(-5)))
# the 'did not come back' path, on a fresh outing of C on the no-location event
r = wx("out","T003","NOLOC",pos="1.6,101.2,500",dev="devC",reason="Mesyuarat PIBG",back=T(60))
check("location-off event: accepted far away", r.get("ok"), True)
check("location-off event: no position stored", q("select count(*) from work_exits where staff_id='00000000-0000-0000-0000-00000000000c' and out_lat is null and out_accuracy is null and out_distance is null"), "1")
cid = q("select id from work_exits where staff_id='00000000-0000-0000-0000-00000000000c'")
check("went home by admin", j(q(f"select exit_set_return('{cid}',null,'Tidak kembali, maklum kerani',true)", *M)), {"ok": True})
check("log gone_home by admin", q("select status||'|'||back_source from work_exit_log where staff_code='T003'"), "gone_home|manual")
# who can read
check("anon cannot read table", q("select count(*) from work_exits", "anon"), lambda s: "permission denied" in s)
check("anon cannot read log", q("select count(*) from work_exit_log", "anon"), lambda s: "permission denied" in s)
check("non-admin sees no rows", q("select count(*) from work_exit_log", "authenticated", "00000000-0000-0000-0000-0000000000a3"), "0")
check("operator sees rows", q("select count(*) from work_exit_log", "authenticated", "00000000-0000-0000-0000-0000000000a2"), "5")
check("operator cannot write", q("delete from work_exits", "authenticated", "00000000-0000-0000-0000-0000000000a2"), lambda s: "permission denied" in s)
check("owner cannot update directly", q("update work_exits set reason='x y'", *M), lambda s: "permission denied" in s)
check("list_events has allow_exit", q("select string_agg(event_code||':'||allow_exit, ',' order by event_code) from list_events()", "anon"), lambda s: "HARIAN:true" in s and "MEET:false" in s)
check("remove_event archives event with outings", q("select remove_event('00000000-0000-0000-0000-0000000000e4')", *M), "archived")
print(f"\n{n - fails}/{n} passed"); sys.exit(1 if fails else 0)
