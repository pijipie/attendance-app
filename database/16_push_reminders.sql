-- =====================================================================
--  ATTENDANCE SYSTEM  -  16_push_reminders.sql
--  Push reminders on staff phones (12 Oct 2026).
--
--  Paste this WHOLE file into Supabase > SQL Editor and press RUN (once).
--  Safe to run again. Needs file 15 first.
--  Before running it: Database > Extensions, switch on pg_cron and pg_net.
--  (Without pg_cron the file still runs; only the timer is not made.)
--
--  What it does
--    * A phone can sign up for reminders with the "Remind Me" button on the
--      staff page. Only the phone's push address is kept, no name.
--    * At that person's first accepted check-in from that phone, the
--      address is linked to them, so it can also get the "not yet"
--      reminders. A typed staff code never links anything.
--    * Three reminders, worked out from the reminder event's sessions for
--      that day (Daily Attendance). No session that day: no reminder.
--        R1  06:30            every signed-up phone      "attendance is open, record before 07:40"
--        R2  late time + 5    linked, no check-in today at any event
--        R3  check-out + 15   linked, checked in here today, no check-out, not gone home
--      Each phone gets each reminder at most once a day (push_log).
--      The words never carry a name, a code or anyone else's status.
--    * A timer (pg_cron, every minute) asks push_due() what is due and,
--      only when something is, hands the list to the Edge Function
--      send-reminders (pg_net), which signs and sends the messages.
--
--  THE TIMER IS MADE PAUSED. To switch it on (spec section 8, Tuesday):
--      select cron.alter_job((select jobid from cron.job where jobname = 'push-reminders'), active := true);
--  To pause it again: the same line with active := false.
--  Running this file again pauses it again.
--
--  To send by hand, at any time of day, for testing (from this SQL Editor only):
--      select push_tick('2026-10-12 07:45:00+08');     -- sends what would be due at that moment
--  It needs the two Vault secrets (push_function_url, push_shared_secret).
--
--  PART A : push_subscriptions, push_log, org_settings.push_event_id
--  PART B : push_subscribe(), push_unsubscribe(), push_link()   - doors for staff phones
--  PART C : push_count()                                         - the admin's count
--  PART D : push_due(), push_tick(), push_report()               - the timer and the Edge Function
--  PART E : the timer (pg_cron), made paused
--  PART F : who may use which door
--
--  What does NOT change
--    * No existing row is changed, except org_settings.push_event_id,
--      which is set to the Daily Attendance event (0001) if it is empty.
--    * check_in(), the counters and stepping out are not touched.
-- =====================================================================

begin;      -- all or nothing: if any part fails, nothing in this file is kept

do $$
begin
  if to_regprocedure('public.exit_rules(text,text)') is null then
    raise exception 'STOP: run 15_step_out_time_left.sql first. Nothing was changed.';
  end if;
end $$;


-- =====================================================================
-- PART A : TABLES
--   No policies at all (like qr_tokens): nobody reads or writes them
--   through the website. Only the functions below touch them.
-- =====================================================================
create table if not exists push_subscriptions (
  id            bigint generated always as identity primary key,
  endpoint      text not null unique check (endpoint ~ '^https://' and length(endpoint) <= 1000),   -- the phone's push address
  p256dh        text not null check (length(p256dh) between 1 and 200),
  auth          text not null check (length(auth) between 1 and 100),
  device_id     text not null check (device_id ~ '^[A-Za-z0-9_.:-]{1,64}$'),                       -- the staff page's device ID
  lang          text not null default 'en' check (lang in ('ms', 'en')),                            -- the language of the reminders
  staff_id      uuid references staff(id) on delete set null,                                       -- empty until that person's own check-in links it
  created_at    timestamptz not null default now(),
  linked_at     timestamptz,
  last_sent_at  timestamptz,
  fail_count    integer not null default 0
);
create index if not exists push_subscriptions_device_idx on push_subscriptions (device_id);
create index if not exists push_subscriptions_staff_idx  on push_subscriptions (staff_id);

create table if not exists push_log (
  subscription_id bigint not null references push_subscriptions(id) on delete cascade,
  kind            text not null check (kind in ('R1', 'R2', 'R3')),
  day             date not null,                                  -- the Malaysian date
  at              timestamptz not null default now(),
  primary key (subscription_id, kind, day)                        -- a reminder can never go twice to one phone on one day
);

alter table push_subscriptions enable row level security;
alter table push_log           enable row level security;

-- The event whose sessions drive the reminders. Removing that event empties it.
alter table org_settings add column if not exists push_event_id uuid references events(id) on delete set null;
update org_settings
   set push_event_id = (select id from events where event_code = '0001' and archived_at is null)
 where id = 1 and push_event_id is null;


-- =====================================================================
-- PART B : DOORS FOR STAFF PHONES (no login)
--   The same habits as report_location_problem(): every text is measured
--   first, the answer is always {"ok": true}, and there is a brake.
-- =====================================================================

-- Sign up, or new keys for an address already kept (the link and the language stay).
-- Brake: at most 3 addresses per device ID, and 500 new ones a day for the whole school.
create or replace function push_subscribe(p_endpoint text, p_p256dh text, p_auth text, p_device_id text, p_lang text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_done  constant jsonb := jsonb_build_object('ok', true);
  v_today timestamptz := ((now() at time zone 'Asia/Kuala_Lumpur')::date)::timestamp at time zone 'Asia/Kuala_Lumpur';
begin
  if coalesce(length(p_endpoint), 0) not between 1 and 1000
     or coalesce(length(p_p256dh), 0) not between 1 and 200
     or coalesce(length(p_auth), 0) not between 1 and 100
     or coalesce(length(p_device_id), 0) not between 1 and 200
     or coalesce(length(p_lang), 0) > 10 then
    return v_done;
  end if;
  p_device_id := trim(p_device_id);
  if p_endpoint !~ '^https://[^[:space:]]+$'
     or p_device_id !~ '^[A-Za-z0-9_.:-]{1,64}$'
     or p_p256dh !~ '^[A-Za-z0-9_=-]+$'
     or p_auth !~ '^[A-Za-z0-9_=-]+$' then
    return v_done;
  end if;

  update push_subscriptions set p256dh = p_p256dh, auth = p_auth where endpoint = p_endpoint;
  if found then
    return v_done;
  end if;

  if (select count(*) from push_subscriptions where device_id = p_device_id) >= 3
     or (select count(*) from push_subscriptions where created_at >= v_today) >= 500 then
    return v_done;
  end if;

  insert into push_subscriptions (endpoint, p256dh, auth, device_id, lang)
  values (p_endpoint, p_p256dh, p_auth, p_device_id, case when p_lang = 'ms' then 'ms' else 'en' end)
  on conflict (endpoint) do nothing;
  return v_done;
end;
$$;

-- Stop reminders: the address and its link are deleted.
create or replace function push_unsubscribe(p_endpoint text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if coalesce(length(p_endpoint), 0) between 1 and 1000 then
    delete from push_subscriptions where endpoint = p_endpoint;
  end if;
  return jsonb_build_object('ok', true);
end;
$$;

-- Link an address to the person whose accepted check-in today, to the reminder event, came from this
-- same phone. The latest such check-in wins, so a later check-in by someone else on the phone moves the
-- link to them. Anything else stores nothing and gets the same answer.
create or replace function push_link(p_endpoint text, p_device_id text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_done  constant jsonb := jsonb_build_object('ok', true);
  v_event uuid;
  v_staff uuid;
begin
  if coalesce(length(p_endpoint), 0) not between 1 and 1000
     or coalesce(length(p_device_id), 0) not between 1 and 200 then
    return v_done;
  end if;
  p_device_id := trim(p_device_id);
  if p_device_id !~ '^[A-Za-z0-9_.:-]{1,64}$' then
    return v_done;
  end if;

  select push_event_id into v_event from org_settings where id = 1;
  if v_event is null then
    return v_done;
  end if;

  select a.staff_id into v_staff
    from attendance a
    join staff s on s.id = a.staff_id and s.active
   where a.event_id = v_event and a.status = 'present'
     and a.attendance_date = (now() at time zone 'Asia/Kuala_Lumpur')::date
     and a.device_id = p_device_id
   order by a.checked_in_at desc
   limit 1;
  if v_staff is null then
    return v_done;
  end if;

  update push_subscriptions
     set staff_id = v_staff, linked_at = now()
   where endpoint = p_endpoint and device_id = p_device_id
     and staff_id is distinct from v_staff;
  return v_done;
end;
$$;


-- =====================================================================
-- PART C : THE ADMIN'S COUNT
--   Numbers only: how many phones have reminders, and how many are linked.
-- =====================================================================
create or replace function push_count() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  return jsonb_build_object('phones', (select count(*) from push_subscriptions),
                            'linked', (select count(*) from push_subscriptions where staff_id is not null));
end;
$$;


-- =====================================================================
-- PART D : THE TIMER
--   push_due(p_at) : the reminders due at p_at, to which phones, with which words.
--                    It writes push_log in the same step, so nothing goes twice even
--                    if the timer runs late or twice. A reminder still goes out up to
--                    15 minutes after its time; after that it is skipped.
--                    Times are worked out as dates plus times, never as clock times
--                    plus minutes, so nothing wraps past midnight (the 9 Oct lesson).
--                    p_at exists so tests and the maintainer can try any time of day.
--   push_tick(p_at): what the timer runs every minute. Only when something is due, it
--                    posts the list to the Edge Function, with the shared secret.
--   push_report()  : the Edge Function's answer: sent, gone (deleted), failed
--                    (deleted after 5 failures in a row).
-- =====================================================================
create or replace function push_due(p_at timestamptz default now())
returns table (endpoint text, p256dh text, auth text, title text, body text, kind text)
language plpgsql security definer set search_path = public as $$
declare
  v_local timestamp := p_at at time zone 'Asia/Kuala_Lumpur';
  v_day   date      := (p_at at time zone 'Asia/Kuala_Lumpur')::date;
  v_event uuid;
  v_start time;                  -- the check-in session's late time
  v_end   time;                  -- the check-out session's start
begin
  select o.push_event_id into v_event
    from org_settings o join events e on e.id = o.push_event_id
   where o.id = 1 and e.active and e.archived_at is null;
  if v_event is null then
    return;
  end if;
  select d.work_start, d.work_end into v_start, v_end from work_day_of(v_event, v_day) d;

  return query
  with due (k, due_at) as (
    values ('R1', case when v_start is not null then v_day + time '06:30' end),
           ('R2', v_day + v_start + interval '5 minutes'),
           ('R3', v_day + v_end + interval '15 minutes')
  ),
  now_due as (
    select d.k from due d
     where d.due_at is not null and v_local >= d.due_at and v_local < d.due_at + interval '15 minutes'
  ),
  who as (
    select s.id, s.endpoint, s.p256dh, s.auth, s.lang, n.k
      from push_subscriptions s
      cross join now_due n
     where n.k = 'R1'
        -- R2: linked, active, and no accepted check-in today at ANY event (an off-site briefing counts)
        or (n.k = 'R2' and s.staff_id is not null
            and exists (select 1 from staff st where st.id = s.staff_id and st.active)
            and not exists (select 1 from attendance a
                             where a.staff_id = s.staff_id and a.attendance_date = v_day and a.status = 'present'))
        -- R3: linked, active, checked in here today, no accepted check-out here, not gone home through a step-out
        or (n.k = 'R3' and s.staff_id is not null
            and exists (select 1 from staff st where st.id = s.staff_id and st.active)
            and exists (select 1 from attendance a left join event_windows w on w.id = a.window_id
                         where a.staff_id = s.staff_id and a.event_id = v_event and a.attendance_date = v_day
                           and a.status = 'present' and coalesce(w.counts_as, 'in') = 'in')
            and not exists (select 1 from attendance a join event_windows w on w.id = a.window_id
                             where a.staff_id = s.staff_id and a.event_id = v_event and a.attendance_date = v_day
                               and a.status = 'present' and w.counts_as = 'out')
            and not exists (select 1 from work_exits x
                             where x.staff_id = s.staff_id and x.exit_date = v_day and x.going_home))
  ),
  logged as (
    insert into push_log (subscription_id, kind, day)
    select w.id, w.k, v_day from who w
    on conflict do nothing
    returning subscription_id, push_log.kind
  )
  select w.endpoint, w.p256dh, w.auth,
         case w.lang when 'ms' then 'Kehadiran Staf' else 'Staff Attendance' end,
         case w.k
           when 'R1' then case w.lang when 'ms' then 'Kehadiran hari ini dibuka. Rekod sebelum ' || to_char(v_start, 'HH24:MI') || '.'
                                      else 'Today''s attendance is open. Record before ' || to_char(v_start, 'HH24:MI') || '.' end
           when 'R2' then case w.lang when 'ms' then 'Kehadiran anda belum direkod.' else 'Your attendance is not recorded yet.' end
           else           case w.lang when 'ms' then 'Anda belum daftar keluar hari ini.' else 'You have not checked out today.' end
         end,
         w.k
    from who w
    join logged l on l.subscription_id = w.id and l.kind = w.k;
end;
$$;

create or replace function push_tick(p_at timestamptz default now()) returns integer
language plpgsql security definer set search_path = public as $$
declare
  v_url    text;
  v_secret text;
  v_msgs   jsonb;
begin
  -- The secrets first: without them nothing is logged, so nothing is lost.
  select decrypted_secret into v_url    from vault.decrypted_secrets where name = 'push_function_url';
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'push_shared_secret';
  if v_url is null or v_secret is null then
    raise warning 'push_tick: the Vault secrets push_function_url and push_shared_secret are missing; nothing sent';
    return 0;
  end if;

  select jsonb_agg(jsonb_build_object('endpoint', d.endpoint, 'p256dh', d.p256dh, 'auth', d.auth,
                                      'title', d.title, 'body', d.body, 'kind', d.kind))
    into v_msgs
    from push_due(p_at) d;
  if v_msgs is null then
    return 0;
  end if;

  perform net.http_post(url := v_url,
                        body := jsonb_build_object('messages', v_msgs),
                        headers := jsonb_build_object('Content-Type', 'application/json', 'x-push-secret', v_secret),
                        timeout_milliseconds := 10000);
  return jsonb_array_length(v_msgs);
end;
$$;

create or replace function push_report(p_sent text[], p_gone text[], p_failed text[]) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if coalesce(array_length(p_sent, 1), 0) > 5000 or coalesce(array_length(p_gone, 1), 0) > 5000
     or coalesce(array_length(p_failed, 1), 0) > 5000 then
    return jsonb_build_object('ok', false);
  end if;
  update push_subscriptions set last_sent_at = now(), fail_count = 0 where endpoint = any (coalesce(p_sent, '{}'));
  delete from push_subscriptions where endpoint = any (coalesce(p_gone, '{}'));             -- the push service says the address is gone
  update push_subscriptions set fail_count = fail_count + 1 where endpoint = any (coalesce(p_failed, '{}'));
  delete from push_subscriptions where endpoint = any (coalesce(p_failed, '{}')) and fail_count >= 5;
  return jsonb_build_object('ok', true);
end;
$$;


-- =====================================================================
-- PART E : THE TIMER (pg_cron), MADE PAUSED
--   Every minute: select push_tick(). Switched on by hand (see the top of this file).
-- =====================================================================
do $$
declare
  v_job bigint;
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'push-reminders';
    v_job := cron.schedule('push-reminders', '* * * * *', 'select push_tick()');
    perform cron.alter_job(v_job, active := false);
  end if;
end $$;


-- =====================================================================
-- PART F : WHO MAY USE WHICH DOOR
--   Supabase gives everything on a new table to everyone by default.
--   Take it all away first, then give on purpose.
-- =====================================================================
revoke all on push_subscriptions from anon, authenticated;
revoke all on push_log           from anon, authenticated;

revoke all on function push_subscribe(text, text, text, text, text) from public, anon, authenticated;
grant execute on function push_subscribe(text, text, text, text, text) to anon, authenticated;
revoke all on function push_unsubscribe(text) from public, anon, authenticated;
grant execute on function push_unsubscribe(text) to anon, authenticated;
revoke all on function push_link(text, text) from public, anon, authenticated;
grant execute on function push_link(text, text) to anon, authenticated;
revoke all on function push_count() from public, anon, authenticated;
grant execute on function push_count() to authenticated;                     -- the function itself still asks is_admin()
revoke all on function push_due(timestamptz) from public, anon, authenticated;   -- the timer and the SQL Editor only
revoke all on function push_tick(timestamptz) from public, anon, authenticated;
revoke all on function push_report(text[], text[], text[]) from public, anon, authenticated;
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    grant execute on function push_report(text[], text[], text[]) to service_role;   -- the Edge Function only
  end if;
end $$;

commit;


-- ---------------------------------------------------------------------
-- Quick check. You should see one row:
--   tables_ready       = true
--   public_is_shut_out = true   (no page can read the two tables or start the timer)
--   reminder_event     = the event the reminders follow (Daily Attendance)
--   timer              = 'paused' (or 'pg_cron is not on': switch it on, then run this file again)
--   phones             = 0 at first
-- ---------------------------------------------------------------------
select to_regclass('public.push_subscriptions') is not null and to_regclass('public.push_log') is not null as tables_ready,
       not has_table_privilege('anon', 'public.push_subscriptions', 'select')
         and not has_table_privilege('authenticated', 'public.push_log', 'select')
         and not has_function_privilege('anon', 'public.push_tick(timestamptz)', 'execute')
         and not has_function_privilege('anon', 'public.push_due(timestamptz)', 'execute')
         and has_function_privilege('anon', 'public.push_subscribe(text,text,text,text,text)', 'execute')   as public_is_shut_out,
       (select e.name from org_settings o join events e on e.id = o.push_event_id where o.id = 1)        as reminder_event,
       case when to_regclass('cron.job') is null then 'pg_cron is not on'
            else (xpath('/row/s/text()', query_to_xml(          -- read cron.job only when it exists
                    'select case when bool_or(active) then ''ON'' when count(*) > 0 then ''paused'' else ''missing'' end as s
                       from cron.job where jobname = ''push-reminders''', false, true, '')))[1]::text end              as timer,
       (select count(*) from push_subscriptions)                                                        as phones;
