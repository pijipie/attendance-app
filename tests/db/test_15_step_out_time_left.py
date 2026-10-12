import subprocess, json, sys, os, shlex
# SQL file 15: the midnight fix (exit_latest) and the time left today on the phone that checked in.
# Uses fixed times: the working day runs 00:01 to 23:58, so the test does not depend on the hour.
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

hhmm = q("select to_char(now() at time zone 'Asia/Kuala_Lumpur','HH24:MI')")
assert "00:02" <= hhmm <= "19:30", "run between 00:02 and 19:30 Malaysian time (the working day here is 00:01 to 23:58, and the test writes times up to 4 hours ahead)"
T = lambda m: q(f"select to_char(date_trunc('minute', now() at time zone 'Asia/Kuala_Lumpur')::time + interval '{m} minutes', 'HH24:MI')")

# ---- 1. the helper, with fixed times (the wrap case from 9 Oct, and the edges) ----
L = lambda now, end, left: q(f"select to_char(exit_latest('{now}', '{end}', {left}), 'HH24:MI')")
check("20:06, day ends 21:00, 240 left -> 21:00 (was 00:06)", L("20:06", "21:00", 240), "21:00")
check("20:06 + 4 h never wraps: written 20:40 is allowed", L("20:06", "21:00", 240) >= "20:40", True)
check("20:06: written 21:01 is past the latest", "21:01" > L("20:06", "21:00", 240), True)
check("10:00, 225 left -> 13:45", L("10:00", "15:30", 225), "13:45")
check("10:00, 210 left -> 13:30", L("10:00", "15:30", 210), "13:30")
check("one minute before the end -> the end", L("15:29", "15:30", 240), "15:30")
check("nothing left -> now", L("12:00", "15:30", 0), "12:00")
check("late evening, day ends 23:59 -> 23:59", L("22:30", "23:59", 240), "23:59")
check("work_exit uses the helper", q("select pg_get_functiondef('public.work_exit(text,text,text,double precision,double precision,real,text,text,text,boolean)'::regprocedure) like '%exit_latest(v_minute, v_end, v_left)%'"), "t")
check("exit_rules uses the helper", q("select pg_get_functiondef('public.exit_rules(text,text)'::regprocedure) like '%exit_latest(v_minute, v_end, %'"), "t")
check("old one-input exit_rules is gone", q("select to_regprocedure('public.exit_rules(text)') is null"), "t")
check("anon cannot call the helper", q("select exit_latest('10:00','15:30',10)", "anon"), lambda s: "permission denied" in s)

# ---- 2. a day with fixed working hours, 00:01 to 23:58 ----
q("""
insert into staff (id, staff_code, full_name) values
 ('00000000-0000-0000-0000-0000000000a1','S001','Alpha'), ('00000000-0000-0000-0000-0000000000a2','S002','Bravo'),
 ('00000000-0000-0000-0000-0000000000a3','S003','Charlie'), ('00000000-0000-0000-0000-0000000000a4','S004','Delta'),
 ('00000000-0000-0000-0000-0000000000a5','S005','Echo');
insert into events (id, event_code, name, require_qr, allow_exit, require_location) values
 ('00000000-0000-0000-0000-0000000000e1','DAY','Daily',false,true,false),
 ('00000000-0000-0000-0000-0000000000e2','OTHER','Other day event',false,true,false);
insert into event_windows (id, event_id, label, start_time, end_time, late_after, counts_as) values
 ('00000000-0000-0000-0000-0000000000f1','00000000-0000-0000-0000-0000000000e1','Masuk','00:00','00:30','00:01','in'),
 ('00000000-0000-0000-0000-0000000000f2','00000000-0000-0000-0000-0000000000e1','Masuk 2','00:00','00:30',null,'in'),
 ('00000000-0000-0000-0000-0000000000f3','00000000-0000-0000-0000-0000000000e1','Pulang','23:58','23:59',null,'out'),
 ('00000000-0000-0000-0000-0000000000f4','00000000-0000-0000-0000-0000000000e2','Masuk','00:00','00:30','00:01','in'),
 ('00000000-0000-0000-0000-0000000000f5','00000000-0000-0000-0000-0000000000e2','Pulang','23:58','23:59',null,'out');
insert into attendance (staff_id, event_id, window_id, checked_in_at, device_id, status) values
 ('00000000-0000-0000-0000-0000000000a1','00000000-0000-0000-0000-0000000000e1','00000000-0000-0000-0000-0000000000f1', now(),'devA','present'),
 ('00000000-0000-0000-0000-0000000000a2','00000000-0000-0000-0000-0000000000e1','00000000-0000-0000-0000-0000000000f1', now(),'devB','present'),
 ('00000000-0000-0000-0000-0000000000a5','00000000-0000-0000-0000-0000000000e1','00000000-0000-0000-0000-0000000000f1', now(),'devE','present'),
 ('00000000-0000-0000-0000-0000000000a5','00000000-0000-0000-0000-0000000000e1','00000000-0000-0000-0000-0000000000f2', now(),'devR','rejected'),
 -- two people on one phone (two sessions): nobody's time left is shown on it
 ('00000000-0000-0000-0000-0000000000a3','00000000-0000-0000-0000-0000000000e1','00000000-0000-0000-0000-0000000000f1', now(),'devShared','present'),
 ('00000000-0000-0000-0000-0000000000a4','00000000-0000-0000-0000-0000000000e1','00000000-0000-0000-0000-0000000000f2', now(),'devShared','present');
""")
R = lambda dev=None, event="DAY": j(q(f"select exit_rules('{event}', {'null' if dev is None else repr(dev)})", "anon"))
def wx(action, staff, dev, reason=None, back=None, home=False):
    r = "null" if reason is None else "'%s'" % reason
    b = "null" if back is None else "'%s'" % back
    return j(q(f"select work_exit('{action}','{staff}','DAY',null,null,null,'{dev}',{r},{b},{str(home).lower()})", "anon"))
# "now" and "latest" move with the clock: compare the rest, and check "latest" against the reply's own "now".
G = lambda d: {k: v for k, v in d.items() if k not in ("now", "latest")}
LATEST = lambda d, left: d.get("latest") == q(f"select to_char(exit_latest('{d.get('now')}', '23:58', {left}), 'HH24:MI')")
PERSONAL = {"personal", "minutes_left", "out_now", "back_by", "gone_home"}
ALLOWED = {"ok", "limit_minutes", "work_start", "work_end", "now", "open_now", "latest"} | PERSONAL

g = R()
check("no device: general answer", (g.get("ok"), g.get("work_start"), g.get("work_end"), LATEST(g, 240)), (True, "00:01", "23:58", True))
check("no device: nothing personal", PERSONAL & set(g), set())
check("one-input call still works (old page)", G(j(q("select exit_rules(p_event_code => 'DAY')", "anon"))), G(g))
check("another phone: general answer", G(R("devZ")), G(g))
check("bad device ID: general answer, no error", G(R("bad id!")), G(g))
check("oversized device ID: general answer, no error", G(R("x" * 300)), G(g))
check("phone with only a rejected check-in: general answer", G(R("devR")), G(g))
check("phone shared by two people: general answer", G(R("devShared")), G(g))
check("same phone, other event (no check-in there): general answer", set(R("devA", "OTHER")) & PERSONAL, set())
a = R("devA")
check("phone that checked in: personal", (a.get("personal"), a.get("minutes_left"), LATEST(a, 240)), (True, 240, True))
check("device ID is trimmed like check_in()", R(" devA ").get("personal"), True)
check("personal answer: only allowed fields", set(a) - ALLOWED, set())
check("personal answer: no name, code or reason", any(k in a for k in ("name", "staff_code", "full_name", "reason")), False)

# ---- 3. the maintainer's example: two step-outs of 15 minutes -> 225, then 210 ----
def closed(staff, mins_ago_out, mins_ago_back):
    q(f"""insert into work_exits (staff_id,event_id,exit_date,out_at,reason,planned_back,back_at,back_source,out_device)
          values ('{staff}','00000000-0000-0000-0000-0000000000e1',(now() at time zone 'Asia/Kuala_Lumpur')::date,
                  date_trunc('minute', now()) - interval '{mins_ago_out} minutes','Urusan','23:00',
                  date_trunc('minute', now()) - interval '{mins_ago_back} minutes','recorded','dev')""")
closed("00000000-0000-0000-0000-0000000000a1", 120, 105)
check("after one step-out of 15 min: 225 left", R("devA").get("minutes_left"), 225)
check("latest uses that person's 225", LATEST(R("devA"), 225), True)
closed("00000000-0000-0000-0000-0000000000a1", 60, 45)
check("after two step-outs of 15 min: 210 left", R("devA").get("minutes_left"), 210)
check("Bravo's phone is not affected", R("devB").get("minutes_left"), 240)

# the same, through work_exit(): Masuk semula says what is left
q("""insert into work_exits (staff_id,event_id,exit_date,out_at,reason,planned_back,out_device)
     values ('00000000-0000-0000-0000-0000000000a2','00000000-0000-0000-0000-0000000000e1',(now() at time zone 'Asia/Kuala_Lumpur')::date,
             date_trunc('minute', now()) - interval '15 minutes','Bank','23:00','devB')""")
b = R("devB")
check("out now: shown to that phone", (b.get("out_now"), b.get("back_by")), (True, "23:00"))
check("out now: not shown to another phone", "out_now" in R("devA") or "out_now" in R("devZ") or "out_now" in R(), False)
r = wx("back", "S002", "devB")
check("back: minutes_left 225 after 15 min", (r.get("ok"), r.get("away_minutes"), r.get("minutes_left")), (True, 15, 225))
q("""insert into work_exits (staff_id,event_id,exit_date,out_at,reason,planned_back,out_device)
     values ('00000000-0000-0000-0000-0000000000a2','00000000-0000-0000-0000-0000000000e1',(now() at time zone 'Asia/Kuala_Lumpur')::date,
             date_trunc('minute', now()) - interval '15 minutes','Pos','23:00','devB')""")
r = wx("back", "S002", "devB")
check("back again: minutes_left 210", (r.get("day_minutes"), r.get("minutes_left")), (30, 210))
check("back: existing fields unchanged", set(r) >= {"ok", "action", "name", "away_minutes", "late_minutes", "day_minutes", "over_limit"}, True)

# ---- 4. Keluar: what is left if back on time ----
r = wx("out", "S005", "devE", reason="Klinik", back=T(30))
check("out: minutes_left_if_on_time = 240 - 30", (r.get("ok"), r.get("back_by"), r.get("minutes_left_if_on_time")), (True, T(30), 210))
r = wx("out", "S005", "devE", reason="Klinik", back=T(30))
check("refusal words unchanged (already_out)", r.get("reason"), "already_out")
r = j(q(f"select work_exit('out','S001','DAY',null,null,null,'devA','Bank','{T(211)}',false)", "anon"))
check("return_too_late: latest from the helper, 210 left", (r.get("reason"), r.get("latest"), r.get("minutes_left")), ("return_too_late", T(210), 210))

# ---- 5. going home: shown only to that phone ----
r = wx("out", "S002", "devB", reason="Anak demam", home=True)
check("B goes home", (r.get("ok"), r.get("going_home")), (True, True))
check("gone home: shown to that phone", R("devB").get("gone_home"), True)
check("gone home: not shown to another phone", any("gone_home" in R(d) for d in (None, "devA", "devZ")), False)
check("Echo's phone: out now", (R("devE").get("out_now"), R("devE").get("back_by")), (True, T(30)))

print(f"\n{n - fails}/{n} passed"); sys.exit(1 if fails else 0)
