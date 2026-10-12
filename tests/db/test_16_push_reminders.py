import subprocess, json, sys, os, shlex
# SQL file 16: push reminders. push_due() is always asked at fixed times (p_at), never "now".
# Mon 12 Oct 2026, Fri 16 Oct, Sat 17 Oct, Mon 19 Oct (evening event). Malaysian time (+08).
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

U = lambda c: "00000000-0000-0000-0000-0000000000" + c
EP = lambda k: "https://push.example.test/send/" + k
# Who gets what at one moment, as "kind:endpoint-key:lang|body", sorted. push_due() logs what it returns,
# so each moment is asked ONCE: due("2026-10-12 06:30") -> ["R1:a:en|Today's attendance is open. ...", ...]
LAST = {}
def due(at, bodies=False):
    out = q(f"select kind || ':' || replace(endpoint, '{EP('')}', '') || ':' || case when title = 'Kehadiran Staf' then 'ms' else 'en' end || '|' || body from push_due('{at}+08')")
    rows = sorted(out.splitlines()) if out and not out.startswith("ERR") else ([] if not out else [out])
    LAST.clear(); LAST.update({r.split("|")[0].split(":")[1]: r.split("|", 1)[1] for r in rows if "|" in r})
    return rows if bodies else [r.split("|")[0] for r in rows]

q(f"""
insert into staff (id, staff_code, full_name, active) values
 ('{U('a1')}','P001','Alpha',true), ('{U('a2')}','P002','Bravo',true), ('{U('a3')}','P003','Charlie',true),
 ('{U('a4')}','P004','Delta',false), ('{U('a5')}','P005','Echo',true), ('{U('a6')}','P006','Foxtrot',true),
 ('{U('a7')}','P007','Golf',true), ('{U('a8')}','P008','Hotel',true);
insert into events (id, event_code, name, require_qr, allow_exit, require_location) values
 ('{U('e1')}','DAILY','Daily',false,true,false), ('{U('e2')}','OFFSITE','Briefing elsewhere',false,false,false),
 ('{U('e3')}','EVE','Evening',false,false,false);
insert into event_windows (id, event_id, label, start_time, end_time, late_after, counts_as, weekdays) values
 ('{U('f1')}','{U('e1')}','Masuk','06:45','09:00','07:40','in','{{1,2,3,4,5}}'),
 ('{U('f2')}','{U('e1')}','Pulang','15:30','17:00',null,'out','{{1,2,3,4}}'),
 ('{U('f3')}','{U('e1')}','Pulang Jumaat','12:00','13:00',null,'out','{{5}}'),
 ('{U('f4')}','{U('e2')}','Taklimat','08:00','12:00',null,null,null),
 ('{U('f5')}','{U('e3')}','Masuk malam','20:00','21:00','20:25','in',null),
 ('{U('f6')}','{U('e3')}','Pulang malam','23:50','23:59',null,'out',null);
-- Monday 12 Oct
insert into attendance (staff_id, event_id, window_id, checked_in_at, attendance_date, device_id, status) values
 ('{U('a1')}','{U('e1')}','{U('f1')}','2026-10-12 07:30+08','2026-10-12','dA','present'),
 ('{U('a3')}','{U('e2')}','{U('f4')}','2026-10-12 08:10+08','2026-10-12','dC','present'),
 ('{U('a4')}','{U('e1')}','{U('f1')}','2026-10-12 07:31+08','2026-10-12','dD','present'),
 ('{U('a5')}','{U('e1')}','{U('f1')}','2026-10-12 07:32+08','2026-10-12','dE','present'),
 ('{U('a5')}','{U('e1')}','{U('f2')}','2026-10-12 15:35+08','2026-10-12','dE','present'),
 ('{U('a6')}','{U('e1')}','{U('f1')}','2026-10-12 07:33+08','2026-10-12','dF','present'),
 ('{U('a2')}','{U('e1')}','{U('f1')}','2026-10-12 07:34+08','2026-10-12','dB','rejected'),
 -- Friday 16 Oct
 ('{U('a1')}','{U('e1')}','{U('f1')}','2026-10-16 07:30+08','2026-10-16','dA','present');
insert into work_exits (staff_id, event_id, exit_date, out_at, reason, going_home, out_device)
 values ('{U('a6')}','{U('e1')}','2026-10-12','2026-10-12 11:00+08','Anak demam',true,'dF');
update org_settings set push_event_id = '{U('e1')}' where id = 1;
""")

# ---- 1. the doors for phones ----
def sub(key, dev, lang="en", ep=None, p256="BKey" + "x" * 20, auth="AuthKey123"):
    return j(q(f"select push_subscribe('{ep or EP(key)}', '{p256}', '{auth}', '{dev}', '{lang}')", "anon"))
for key, dev, lang in [("a", "dA", "en"), ("b", "dB", "ms"), ("u", "dU", "en"), ("c", "dC", "en"), ("d", "dD", "en"), ("e", "dE", "en"), ("f", "dF", "en")]:
    r = sub(key, dev, lang)
check("subscribe answers ok", r, {"ok": True})
check("7 phones kept", q("select count(*) from push_subscriptions"), "7")
for name, r in [("http address", sub("x", "dX", ep="http://push.example.test/send/x")),
                ("address with a space", sub("x", "dX", ep="https://push.example.test/send/x y")),
                ("oversized address", sub("x", "dX", ep="https://p.test/" + "x" * 1000)),
                ("bad device ID", sub("x", "bad id!")),
                ("bad key", sub("x", "dX", p256="a<b>c")),
                ("missing auth", sub("x", "dX", auth=""))]:
    check("bad input answers the same: " + name, r, {"ok": True})
check("bad input stored nothing", q("select count(*) from push_subscriptions"), "7")
for k in ("x1", "x2", "x3"): sub(k, "dSame")
sub("x4", "dSame")
check("brake: at most 3 addresses per device", q("select count(*) from push_subscriptions where device_id = 'dSame'"), "3")
q(f"delete from push_subscriptions where device_id = 'dSame'")
check("anon cannot read push_subscriptions", q("select count(*) from push_subscriptions", "anon"), lambda s: "permission denied" in s)
check("authenticated cannot read push_log", q("select count(*) from push_log", "authenticated", U("b1")), lambda s: "permission denied" in s)
check("anon cannot call push_due", q("select count(*) from push_due()", "anon"), lambda s: "permission denied" in s)
check("anon cannot call push_tick", q("select push_tick()", "anon"), lambda s: "permission denied" in s)
check("anon cannot call push_report", q("select push_report('{}','{}','{}')", "anon"), lambda s: "permission denied" in s)

# Links for the reminder tests are set directly; push_link() itself is tested in section 6.
q(f"""update push_subscriptions s set staff_id = v.st::uuid, linked_at = now()
      from (values ('a','{U('a1')}'), ('b','{U('a2')}'), ('c','{U('a3')}'), ('d','{U('a4')}'), ('e','{U('a5')}'), ('f','{U('a6')}')) v(k, st)
     where s.endpoint = '{EP('')}' || v.k""")

# ---- 2. Monday 12 Oct ----
check("Mon 06:29: nothing yet", due("2026-10-12 06:29"), [])
check("Mon 06:30 R1: every phone, linked or not, in its own language", due("2026-10-12 06:30"),
      ["R1:a:en", "R1:b:ms", "R1:c:en", "R1:d:en", "R1:e:en", "R1:f:en", "R1:u:en"])
check("R1 words EN: the check-in session's late time", LAST.get("a"), "Today's attendance is open. Record before 07:40.")
check("R1 words BM", LAST.get("b"), "Kehadiran hari ini dibuka. Rekod sebelum 07:40.")
check("R1 words: no name or code", any(w in " ".join(LAST.values()) for w in ("Alpha", "Bravo", "P001", "P002")), False)
check("R1 once a day only", due("2026-10-12 06:40"), [])
check("Mon 07:44: R2 not yet", due("2026-10-12 07:44"), [])
check("Mon 07:45 R2: Bravo only (no check-in; the others checked in, off-site, inactive or not linked)", due("2026-10-12 07:45"), ["R2:b:ms"])
check("R2 words BM", LAST.get("b"), "Kehadiran anda belum direkod.")
check("R2 once a day only", due("2026-10-12 07:50"), [])
check("Mon 15:45 R3: Alpha only (Echo checked out, Foxtrot went home, Charlie only off-site, Delta inactive)", due("2026-10-12 15:45"), ["R3:a:en"])
check("R3 words EN", LAST.get("a"), "You have not checked out today.")
check("Mon 16:01: R3 not again", due("2026-10-12 16:01"), [])

# ---- 3. a missed minute: up to 15 minutes late, then skipped ----
check("Tue 06:46: R1 missed by more than 15 min is skipped", due("2026-10-13 06:46"), [])
check("Tue 06:47: still nothing", due("2026-10-13 06:47"), [])
check("Wed 06:44: R1 14 min late still goes", len(due("2026-10-14 06:44")), 7)

# ---- 4. Friday and Saturday ----
check("Fri 15:45: no R3 (Friday check-out is 12:00)", [x for x in due("2026-10-16 15:45") if x.startswith("R3")], [])
check("Fri 12:15 R3: Alpha", due("2026-10-16 12:15"), ["R3:a:en"])
for t in ("06:30", "07:45", "12:15", "15:45"):
    check("Sat " + t + ": nothing (no session)", due("2026-10-17 " + t), [])

# ---- 5. an evening event (the midnight lesson of 9 Oct) ----
q(f"update org_settings set push_event_id = '{U('e3')}' where id = 1")
check("evening Mon 19 Oct 20:30: R2 to linked, active people with no check-in", due("2026-10-19 20:30"),
      ["R2:a:en", "R2:b:ms", "R2:c:en", "R2:e:en", "R2:f:en"])
check("evening 23:59: R3 (due 00:05 tomorrow) not sent early", [x for x in due("2026-10-19 23:59") if x.startswith("R3")], [])
check("next day 00:06: nothing wraps round to the morning", due("2026-10-20 00:06"), [])
q(f"update events set archived_at = now() where id = '{U('e3')}'")
check("archived reminder event: nothing", due("2026-10-21 06:30"), [])
q(f"update events set archived_at = null where id = '{U('e3')}'; update org_settings set push_event_id = '{U('e1')}' where id = 1")

# ---- 6. linking (today, the real date: push_link() looks at today's check-ins) ----
sub("g", "dG")
q(f"insert into attendance (staff_id, event_id, window_id, checked_in_at, device_id, status) values ('{U('a7')}','{U('e1')}','{U('f1')}', now() - interval '10 minutes','dG','present')")
L = lambda key, dev: (q(f"select push_link('{EP(key)}', '{dev}')", "anon"), q(f"select coalesce(staff_id::text, '-') from push_subscriptions where endpoint = '{EP(key)}'"))
check("link: wrong device -> nothing", L("g", "dOther"), ('{"ok": true}', "-"))
check("link: another phone's address -> nothing", L("u", "dG"), ('{"ok": true}', "-"))
check("link: bad device ID -> nothing, same answer", L("g", "bad id!"), ('{"ok": true}', "-"))
check("link: own check-in today -> linked", L("g", "dG"), ('{"ok": true}', U("a7")))
q(f"insert into attendance (staff_id, event_id, window_id, checked_in_at, device_id, status) values ('{U('a8')}','{U('e1')}','{U('f2')}', now(),'dG','present')")
check("link: a later check-in by someone else on the phone moves the link", L("g", "dG")[1], U("a8"))
sub("h", "dH")
check("link: no check-in today from that phone -> nothing", L("h", "dH")[1], "-")
sub("g", "dG", lang="ms", p256="BNewKey" + "y" * 20)
check("re-subscribe: new keys, link and language kept", q(f"select p256dh like 'BNewKey%' and staff_id = '{U('a8')}' and lang = 'en' from push_subscriptions where endpoint = '{EP('g')}'"), "t")

# ---- 7. the admin's count, the Edge Function's report, stopping ----
check("count: anon cannot call", q("select push_count()", "anon"), lambda s: "permission denied" in s)
q(f"""insert into auth.users (id, email, email_confirmed_at) values ('{U('b1')}','nobody@x.test', now()), ('{U('b2')}','op@x.test', now());
      insert into admins (user_id, role) values ('{U('b2')}','operator');""")
check("count: signed in but not an admin", q("select push_count()", "authenticated", U("b1")), lambda s: "not_allowed" in s)
check("count: an admin gets numbers only", j(q("select push_count()", "authenticated", U("b2"))), {"phones": 9, "linked": 7})
check("report: only the Edge Function's role", q("select push_report('{}','{}','{}')", "authenticated", U("b2")), lambda s: "permission denied" in s)
q(f"update push_subscriptions set fail_count = 4 where endpoint in ('{EP('c')}', '{EP('d')}')")
r = q(f"select push_report(array['{EP('d')}'], array['{EP('e')}'], array['{EP('c')}', '{EP('f')}'])", "service_role")
check("report answers ok", r, '{"ok": true}')
check("report: sent resets the failures", q(f"select fail_count || ' ' || (last_sent_at is not null) from push_subscriptions where endpoint = '{EP('d')}'"), "0 true")
check("report: gone address deleted", q(f"select count(*) from push_subscriptions where endpoint = '{EP('e')}'"), "0")
check("report: 5th failure in a row deleted, 1st kept", q(f"select string_agg(replace(endpoint, '{EP('')}', '') || '=' || fail_count, ',' order by endpoint) from push_subscriptions where endpoint in ('{EP('c')}', '{EP('f')}')"), "f=1")
check("stop: push_unsubscribe deletes the address", (q(f"select push_unsubscribe('{EP('a')}')", "anon"), q(f"select count(*) from push_subscriptions where endpoint = '{EP('a')}'")), ('{"ok": true}', "0"))
check("stop: its log rows go with it", q(f"select count(*) from push_log l where not exists (select 1 from push_subscriptions s where s.id = l.subscription_id)"), "0")
q(f"update org_settings set push_event_id = '{U('e3')}' where id = 1; delete from events where id = '{U('e3')}'")   # no attendance, so really deleted
check("deleting the reminder event empties push_event_id", q("select coalesce(push_event_id::text, '-') from org_settings where id = 1"), "-")
check("no reminder event: nothing due", due("2026-10-26 06:30"), [])

print(f"\n{n - fails}/{n} passed"); sys.exit(1 if fails else 0)
