-- =====================================================================
--  ATTENDANCE SYSTEM  -  11_location_problems.sql
--  Check-ins that the phone itself stopped are now recorded (7 Oct 2026).
--
--  Paste this WHOLE file into Supabase > SQL Editor and press RUN (once).
--  Safe to run again.
--
--  Why: when a phone cannot give any position at all (location blocked,
--  location switched off, GPS did not answer), the staff page stops before
--  it ever reaches the database. Nothing was stored, so the admin page
--  showed no trace of that person. On 7 Oct 2026 only 10 of 70 staff were
--  recorded and nobody could tell how many of the others had tried.
--
--  How it works
--    The staff page (v2.8) knocks on one new door, report_location_problem(),
--    when Submit fails for one of these four reasons:
--        denied       the person, or the phone's settings, blocked location
--        off          the device gave no location (location / GPS is off)
--        timeout      the GPS did not answer in time
--        unsupported  the browser cannot give a location at all
--    The database keeps one row: who, which event, which reason, which
--    device, and when. NO position is stored, because there is none.
--    The admin page (Attendance > Rejected) shows these rows in the same
--    list as the attempts the database itself refused.
--
--  PART A : location_problems           - the new table
--  PART B : report_location_problem()   - the new door for staff phones
--  PART C : "remove event" learns about the new table
--  PART D : who may use which door
--
--  What does NOT change
--    * check_in(), list_events(), the counter and the display page are not
--      touched. No existing row is changed.
--    * These rows are never counted as present, late or absent. They are
--      information for the admin, like the refused attempts.
--    * An older staff page simply never knocks on the new door, and a staff
--      page newer than the database gets "no such door" and stops knocking.
--      So this file and the page can be put in, in either order.
--
--  Safety, the same rules as check_in()
--    * The door always gives the same answer, whatever was sent. It cannot
--      be used to find out which staff codes exist.
--    * An unknown staff code or an unknown event stores nothing.
--    * Every text is measured before anything else is done with it.
--    * A brake: at most 10 rows per person, and 10 per device, in any
--      10 minutes; and at most 2,000 rows in one day for the whole school.
--      After that the door still answers, and stores nothing.
-- =====================================================================

begin;      -- all or nothing: if any part fails, nothing in this file is kept
do $$
begin
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'events' and column_name = 'require_location') then
    raise exception 'STOP: 12_location_switch_invited_staff.sql is already installed. This older file is not needed again. Nothing was changed.';
  end if;
end $$;


-- =====================================================================
-- PART A : THE NEW TABLE
--   One row = "this person pressed Submit for this event on this device,
--   and the phone could not give a position, for this reason".
--   Rows are only ever added, by the function in PART B. Nobody can edit
--   or delete them from the admin page (the same as the attendance log).
-- =====================================================================
create table if not exists location_problems (
  id            bigint generated always as identity primary key,
  at            timestamptz not null default now(),
  problem_date  date not null default ((now() at time zone 'Asia/Kuala_Lumpur')::date),   -- the Malaysian date, like attendance_date
  staff_id      uuid not null references staff(id),
  event_id      uuid not null references events(id),
  kind          text not null check (kind in ('denied', 'off', 'timeout', 'unsupported')),
  device_id     text not null check (length(device_id) between 1 and 64)
);
create index if not exists location_problems_day_idx    on location_problems (problem_date, event_id, at);
create index if not exists location_problems_staff_idx  on location_problems (staff_id, at);
create index if not exists location_problems_device_idx on location_problems (device_id, at);

-- Admins of every level may read. There is no policy for adding, changing
-- or deleting: only the function below writes here.
alter table location_problems enable row level security;
drop policy if exists admin_read on location_problems;
create policy admin_read on location_problems for select to authenticated using (is_admin());


-- =====================================================================
-- PART B : THE NEW DOOR FOR STAFF PHONES
--   Called by the staff page without a login, like check_in().
--   It ALWAYS answers {"ok": true}: for a good report, a bad one, an
--   unknown code, or when the brake is on. The page does nothing with the
--   answer, and a stranger learns nothing from it.
-- =====================================================================
create or replace function report_location_problem(
  p_staff_code  text,
  p_event_code  text,
  p_kind        text,
  p_device_id   text
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_staff_id uuid;
  v_event_id uuid;
  v_today    date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
  v_done     constant jsonb := jsonb_build_object('ok', true);
begin
  -- 0. Size limits first, before anything is trimmed, searched or stored
  --    (the same limits as check_in()).
  if coalesce(length(p_staff_code), 0) not between 1 and 60
     or coalesce(length(p_event_code), 0) not between 1 and 60
     or coalesce(length(p_device_id), 0) not between 1 and 200
     or coalesce(length(p_kind), 0) not between 1 and 20 then
    return v_done;
  end if;

  p_staff_code := trim(p_staff_code);
  p_event_code := trim(p_event_code);
  p_device_id  := trim(p_device_id);

  if length(p_staff_code) not between 1 and 20
     or length(p_event_code) not between 1 and 20
     or p_device_id !~ '^[A-Za-z0-9_.:-]{1,64}$'
     or p_kind not in ('denied', 'off', 'timeout', 'unsupported') then
    return v_done;
  end if;

  -- 1. who and which event (case-insensitive codes; archived events do not count)
  select id into v_staff_id from staff
   where lower(staff_code) = lower(p_staff_code) and active;
  select id into v_event_id from events
   where lower(event_code) = lower(p_event_code) and active and archived_at is null;

  -- An unknown person or event stores nothing, and gets the same answer.
  if v_staff_id is null or v_event_id is null then
    return v_done;
  end if;

  -- 2. the brake
  if (select count(*) from location_problems p
       where p.staff_id = v_staff_id and p.at > now() - interval '10 minutes') >= 10
     or (select count(*) from location_problems p
          where p.device_id = p_device_id and p.at > now() - interval '10 minutes') >= 10
     or (select count(*) from location_problems p
          where p.problem_date = v_today) >= 2000 then
    return v_done;
  end if;

  -- 3. keep the row
  insert into location_problems (staff_id, event_id, kind, device_id)
  values (v_staff_id, v_event_id, p_kind, p_device_id);

  return v_done;
end;
$$;


-- =====================================================================
-- PART C : "REMOVE EVENT" LEARNS ABOUT THE NEW TABLE
--   remove_event() from 10, word for word, plus the line marked
--   "NEW in 11": an event that has location problems on record is
--   archived, not deleted, exactly like an event that has attendance.
-- =====================================================================
create or replace function remove_event(p_event_id uuid) returns text
language plpgsql set search_path = public as $$
begin
  if not can_manage() then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  if not exists (select 1 from events where id = p_event_id) then
    return 'not_found';
  end if;
  if exists (select 1 from attendance where event_id = p_event_id)
     or exists (select 1 from attendance_corrections where event_id = p_event_id)
     or exists (select 1 from location_problems where event_id = p_event_id) then           -- NEW in 11
    update events set archived_at = coalesce(archived_at, now()), active = false where id = p_event_id;
    return 'archived';
  end if;
  delete from events where id = p_event_id;      -- its hours go with it
  return 'deleted';
end;
$$;


-- =====================================================================
-- PART D : WHO MAY USE WHICH DOOR
--   Supabase gives everything on a new table to everyone by default.
--   Take it all away first, then give on purpose.
-- =====================================================================
revoke all   on location_problems from anon, authenticated;
grant select on location_problems to authenticated;      -- read only, and row-level security still asks is_admin()

revoke all on function report_location_problem(text, text, text, text) from public, anon, authenticated;
grant execute on function report_location_problem(text, text, text, text) to anon, authenticated;   -- staff phones, no login

revoke all on function remove_event(uuid) from public, anon, authenticated;
grant execute on function remove_event(uuid) to authenticated;               -- the function itself still asks can_manage()

commit;


-- ---------------------------------------------------------------------
-- Quick check. You should see ONE row:
--   new_table_exists     = true
--   public_cannot_read   = true    (a stranger cannot read the list)
--   public_cannot_write  = true    (nobody can write to it directly)
--   phones_can_report    = true    (the staff page may use the new door)
--   rows_so_far          = 0       (until the first phone reports a problem)
-- ---------------------------------------------------------------------
select to_regclass('public.location_problems') is not null                                        as new_table_exists,
       not has_table_privilege('anon', 'public.location_problems', 'select')                      as public_cannot_read,
       not has_table_privilege('anon', 'public.location_problems', 'insert')
         and not has_table_privilege('authenticated', 'public.location_problems', 'insert')       as public_cannot_write,
       has_function_privilege('anon', 'public.report_location_problem(text, text, text, text)', 'execute') as phones_can_report,
       (select count(*) from location_problems)                                                   as rows_so_far;
