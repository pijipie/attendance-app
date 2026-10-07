-- =====================================================================
--  ATTENDANCE SYSTEM  -  10_work_hours.sql
--  Check-in is paired with check-out to work out hours worked (6 Oct 2026).
--
--  Paste this WHOLE file into Supabase > SQL Editor and press RUN (once).
--  Safe to run again.
--
--  Why: the daily event has a morning session (check-in) and an afternoon
--  session (check-out), but until now the database did not know which was
--  which. They were two unrelated lists. The school wants one line per
--  person per day: time in, time out, and how long that is.
--
--  How it works
--    1. A session can be marked as what it COUNTS AS:
--         'in'   = the check-in of the working day   (for example Pagi)
--         'out'  = the check-out of the working day  (for example Petang)
--         empty  = an ordinary session (a meeting, a course): not paired
--    2. For each person, event and day the database takes the accepted
--       check-in from an 'in' session and the accepted check-in from an
--       'out' session and puts them side by side.
--    3. Two lengths are worked out. Example: in 06:58, out 15:42, and the
--       working day is 07:40 to 15:30.
--         actual            06:58 -> 15:42 = 8 h 44 min
--         in working hours  07:40 -> 15:30 = 7 h 50 min
--       Seconds are dropped first, the same way "late" does it, so the
--       numbers match what a person works out from the times on screen.
--    4. Where do "07:40" and "15:30" come from? No new settings:
--         work starts at the 'in' session's "late after" time
--         work ends   when the 'out' session opens (its start time)
--       So Friday can have different hours simply because Friday has its
--       own sessions. If the 'in' session has no "late after" time, only
--       the actual length is shown.
--
--  A missing half
--    If someone has a check-in but no check-out (or the other way round),
--    the day is shown as INCOMPLETE and no length is worked out. Nothing is
--    guessed. The database never fills in a time by itself.
--    An owner or manager may add the missing time by hand, with a reason
--    ("forgot", "phone was flat"). That manual time:
--      * is kept in its OWN table (attendance_corrections). The attendance
--        log is evidence and is still never changed.
--      * is always shown as "manual", with the reason and who entered it.
--      * goes into the activity record, when added and when removed.
--      * can never replace a real check-in: if a recorded one exists for
--        that half, the recorded one is used.
--      * cannot be in the future.
--
--  PART A : sessions can count as check-in or check-out
--  PART B : attendance_corrections  - manual times, in their own table
--  PART C : work_hours              - the paired view the admin page reads
--  PART D : activity record and "remove event" learn about the new table
--  PART E : who may use which door
--
--  What does NOT change
--    * No existing row is changed. Every session keeps "counts as" empty
--      until an admin sets it, so NOTHING behaves differently right after
--      this file is run.
--    * check_in(), list_events(), the counter and the display page are not
--      touched. Staff notice nothing.
--    * Known limit: "in working hours" uses the session's times as they
--      are TODAY. If you change a session's hours later, that figure for
--      past days follows the new hours. The actual times never change.
--
--  AFTER running this file (in the admin page, Events > the event > its hours):
--    set each morning session to "Check-in" and each afternoon session to
--    "Check-out". The Hours list then appears on the Attendance screen.
-- =====================================================================

begin;      -- all or nothing: if any part fails, nothing in this file is kept
do $$
begin
  if to_regclass('public.location_problems') is not null then
    raise exception 'STOP: 11_location_problems.sql is already installed. This older file is not needed again. Nothing was changed.';
  end if;
end $$;


-- =====================================================================
-- PART A : SESSIONS CAN COUNT AS CHECK-IN OR CHECK-OUT
--   Admins already hold the table rights they need on event_windows
--   (06, PART F), and the activity record already watches it.
-- =====================================================================
alter table event_windows add column if not exists counts_as text;

alter table event_windows drop constraint if exists event_windows_counts_as_check;
alter table event_windows add  constraint event_windows_counts_as_check
  check (counts_as is null or counts_as in ('in', 'out'));


-- =====================================================================
-- PART B : MANUAL TIMES
--   One row = "this person's check-in (or check-out) on this day, for this
--   event, was at this time, says this admin, for this reason".
--   At most one manual time per person, event, day and half.
--   A row can be added and removed, never edited: to correct a mistake,
--   remove it and add it again. Both steps land in the activity record.
-- =====================================================================
create table if not exists attendance_corrections (
  id                uuid primary key default gen_random_uuid(),
  staff_id          uuid not null references staff(id),
  event_id          uuid not null references events(id),
  work_date         date not null,
  half              text not null check (half in ('in', 'out')),
  clock_time        time not null,                      -- Malaysian time, whole minutes
  reason            text not null check (length(btrim(reason)) between 3 and 200),
  entered_by        uuid,                               -- filled in by the database, never by the page
  entered_by_email  text,
  entered_at        timestamptz not null default now(),
  unique (staff_id, event_id, work_date, half)
);
create index if not exists attendance_corrections_day_idx on attendance_corrections (event_id, work_date);

-- The database stamps and checks every new manual time itself. Whatever the
-- page sends for "who" and "when" is thrown away and written again here.
create or replace function correction_stamp() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.reason     := btrim(new.reason);
  new.clock_time := date_trunc('minute', new.clock_time);
  new.entered_by := auth.uid();
  new.entered_at := now();
  new.entered_by_email := (select email from auth.users where id = auth.uid());

  -- not in the future (Malaysian time)
  if new.work_date + new.clock_time > (now() at time zone 'Asia/Kuala_Lumpur') then
    raise exception 'fix_future' using errcode = 'P0001';
  end if;

  -- never beside a real check-in: the recorded one is the evidence
  if exists (select 1
               from attendance a
               join event_windows w on w.id = a.window_id
              where a.staff_id = new.staff_id
                and a.event_id = new.event_id
                and a.attendance_date = new.work_date
                and a.status = 'present'
                and w.counts_as = new.half) then
    raise exception 'fix_already_recorded' using errcode = 'P0001';
  end if;

  return new;
end;
$$;

drop trigger if exists correction_stamp on attendance_corrections;
create trigger correction_stamp before insert on attendance_corrections
  for each row execute function correction_stamp();

-- Who may do what. Every admin level may read; only owner and manager may
-- add or remove. There is NO update policy on purpose.
alter table attendance_corrections enable row level security;
drop policy if exists admin_read   on attendance_corrections;
drop policy if exists admin_insert on attendance_corrections;
drop policy if exists admin_delete on attendance_corrections;
create policy admin_read   on attendance_corrections for select to authenticated using (is_admin());
create policy admin_insert on attendance_corrections for insert to authenticated with check (can_manage());
create policy admin_delete on attendance_corrections for delete to authenticated using (can_manage());


-- =====================================================================
-- PART C : work_hours
--   One row per person, event and day that has at least one half.
--   (Someone with nothing at all that day has no row: they are on the
--   "Not checked in" list, as before.)
--
--   Which check-in is used when there is more than one?
--     in  : the earliest accepted check-in of the day in an 'in' session
--     out : the latest accepted check-in of the day in an 'out' session
--     A recorded check-in always wins over a manual time.
--
--   status   complete       both halves, and out is after in
--            no_check_in    only a check-out
--            no_check_out   only a check-in
--            times_wrong    both halves, but out is not after in
--
--   The view runs with the rights of the person asking (security_invoker),
--   so row-level security on the tables underneath still decides.
-- =====================================================================
create or replace view work_hours with (security_invoker = on) as
with halves as not materialized (
  -- recorded: accepted check-ins in sessions that count as in or out
  select a.staff_id, a.event_id, a.attendance_date as work_date, w.counts_as as half,
         'recorded'::text as source, a.checked_in_at as at, a.window_id, a.late_minutes,
         null::text as note, null::text as entered_by_email, null::uuid as correction_id
    from attendance a
    join event_windows w on w.id = a.window_id
   where a.status = 'present' and w.counts_as in ('in', 'out')
  union all
  -- manual: times an admin added by hand
  select c.staff_id, c.event_id, c.work_date, c.half,
         'manual'::text, (c.work_date + c.clock_time) at time zone 'Asia/Kuala_Lumpur', null::uuid, null::integer,
         c.reason, c.entered_by_email, c.id
    from attendance_corrections c
),
pick as not materialized (
  -- one row per person, event, day and half
  select distinct on (staff_id, event_id, work_date, half) *
    from halves
   order by staff_id, event_id, work_date, half,
            (source = 'recorded') desc,                         -- recorded first
            case when half = 'in'  then at end asc,             -- earliest in
            case when half = 'out' then at end desc             -- latest out
),
paired as (
  select staff_id, event_id, work_date,
         i.at as time_in,  i.source as in_source,  i.window_id as in_window,  i.late_minutes as in_late,
         i.note as in_note,  i.entered_by_email as in_entered_by,  i.correction_id as in_correction_id,
         o.at as time_out, o.source as out_source, o.window_id as out_window,
         o.note as out_note, o.entered_by_email as out_entered_by, o.correction_id as out_correction_id
    from      (select * from pick where half = 'in')  i
    full join (select * from pick where half = 'out') o using (staff_id, event_id, work_date)
),
timed as (
  select p.*,
         date_trunc('minute', p.time_in)  as t_in,              -- seconds dropped, like "late"
         date_trunc('minute', p.time_out) as t_out,
         -- Work starts at the 'in' session's "late after" time and ends when the 'out' session opens.
         -- The session the person really used comes first; for a manual time or a missing half,
         -- the session that applies to that weekday and date.
         coalesce(wi.late_after, di.late_after) as official_start,
         coalesce(wo.start_time, dout.start_time) as official_end
    from paired p
    left join event_windows wi on wi.id = p.in_window
    left join event_windows wo on wo.id = p.out_window
    left join lateral (
      select w.late_after from event_windows w
       where w.event_id = p.event_id and w.counts_as = 'in' and w.archived_at is null
         and (w.weekdays is null or extract(isodow from p.work_date)::smallint = any (w.weekdays))
         and (w.starts_on is null or p.work_date >= w.starts_on)
         and (w.ends_on   is null or p.work_date <= w.ends_on)
       order by w.start_time, w.id limit 1) di on true
    left join lateral (
      select w.start_time from event_windows w
       where w.event_id = p.event_id and w.counts_as = 'out' and w.archived_at is null
         and (w.weekdays is null or extract(isodow from p.work_date)::smallint = any (w.weekdays))
         and (w.starts_on is null or p.work_date >= w.starts_on)
         and (w.ends_on   is null or p.work_date <= w.ends_on)
       order by w.start_time desc, w.id limit 1) dout on true
),
edges as (
  select t.*,
         (t.work_date + t.official_start) at time zone 'Asia/Kuala_Lumpur' as start_at,
         (t.work_date + t.official_end)   at time zone 'Asia/Kuala_Lumpur' as end_at
    from timed t
)
select  x.work_date,
        x.event_id,
        x.staff_id,
        s.staff_code,
        s.full_name,
        e.name as event,
        case when x.time_in  is null then 'no_check_in'
             when x.time_out is null then 'no_check_out'
             when x.t_out <= x.t_in  then 'times_wrong'
             else 'complete' end as status,
        x.time_in,
        x.in_source,
        x.time_out,
        x.out_source,
        -- actual: from the time in to the time out
        case when x.t_out > x.t_in
             then (extract(epoch from x.t_out - x.t_in) / 60)::integer end as minutes_actual,
        -- in working hours: only the part between "work starts" and "work ends"
        case when x.t_out > x.t_in and x.start_at is not null and x.end_at is not null
             then greatest(0, (extract(epoch from least(x.t_out, x.end_at) - greatest(x.t_in, x.start_at)) / 60)::integer) end as minutes_official,
        -- late: a recorded check-in keeps the minutes stamped at check-in; a manual time is compared with "work starts"
        case when x.in_source = 'recorded' then x.in_late
             when x.in_source = 'manual' and x.start_at is not null and x.t_in > x.start_at
             then (extract(epoch from x.t_in - x.start_at) / 60)::integer end as late_minutes,
        x.official_start,
        x.official_end,
        x.in_note,
        x.in_entered_by,
        x.in_correction_id,
        x.out_note,
        x.out_entered_by,
        x.out_correction_id
from    edges x
join    staff  s on s.id = x.staff_id
join    events e on e.id = x.event_id;


-- =====================================================================
-- PART D : THE ACTIVITY RECORD AND "REMOVE EVENT" LEARN ABOUT THE NEW TABLE
-- =====================================================================

-- audit_row() from 05_roles_archive_displays.sql, word for word, plus the
-- lines marked "NEW in 10": a manual time is listed as
-- "MNHA 2026-10-05 in 07:35", so the owner can read it without opening it.
create or replace function audit_row() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_row    jsonb;
  v_detail jsonb;
  v_label  text;
begin
  if tg_op = 'INSERT' then
    v_row := to_jsonb(new); v_detail := v_row;
  elsif tg_op = 'DELETE' then
    v_row := to_jsonb(old); v_detail := v_row;
  else
    v_row := to_jsonb(new);
    select jsonb_object_agg(n.key, jsonb_build_array(o.value, n.value)) into v_detail
      from jsonb_each(to_jsonb(new)) n
      join jsonb_each(to_jsonb(old)) o on o.key = n.key
     where n.value is distinct from o.value;
    if v_detail is null then
      return null;                  -- saved with nothing changed: no line
    end if;
  end if;

  v_label := coalesce(v_row->>'event_code', v_row->>'staff_code', v_row->>'label', v_row->>'organization_name');
  if tg_table_name = 'admins' then
    select email into v_label from auth.users where id = (v_row->>'user_id')::uuid;
  end if;
  if tg_table_name = 'attendance_corrections' then                               -- NEW in 10
    select st.staff_code || ' ' || (v_row->>'work_date') || ' ' || (v_row->>'half') || ' ' || left(v_row->>'clock_time', 5)
      into v_label from staff st where st.id = (v_row->>'staff_id')::uuid;
  end if;

  insert into admin_audit (actor, actor_email, action, target, summary, detail)
  values (auth.uid(), (select email from auth.users where id = auth.uid()),
          lower(tg_op), tg_table_name, v_label, v_detail);
  return null;
end;
$$;

drop trigger if exists audit_attendance_corrections on attendance_corrections;
create trigger audit_attendance_corrections after insert or update or delete on attendance_corrections
  for each row execute function audit_row();

-- remove_event() from 05, word for word, plus the line marked "NEW in 10":
-- an event that has manual times is archived, not deleted, exactly like an
-- event that has attendance.
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
     or exists (select 1 from attendance_corrections where event_id = p_event_id) then      -- NEW in 10
    update events set archived_at = coalesce(archived_at, now()), active = false where id = p_event_id;
    return 'archived';
  end if;
  delete from events where id = p_event_id;      -- its hours go with it
  return 'deleted';
end;
$$;


-- =====================================================================
-- PART E : WHO MAY USE WHICH DOOR
--   Supabase gives everything on a new table to everyone by default.
--   Take it all away first, then give on purpose.
-- =====================================================================
revoke all on attendance_corrections from anon, authenticated;
grant select, insert, delete on attendance_corrections to authenticated;     -- no update: a manual time is never edited

revoke all   on work_hours from anon, authenticated;
grant select on work_hours to authenticated;            -- row-level security on the tables underneath still decides

revoke all on function correction_stamp() from public, anon, authenticated;  -- inside helper: nobody calls it directly
revoke all on function audit_row()        from public, anon, authenticated;
revoke all on function remove_event(uuid) from public, anon, authenticated;
grant execute on function remove_event(uuid) to authenticated;               -- the function itself still asks can_manage()

commit;


-- ---------------------------------------------------------------------
-- Quick check. You should see one row for each session that is in use:
--   new_table_exists  = true on every row
--   public_is_shut_out = true on every row
--   counts_as          = empty on every row, until you set it in the admin page
-- ---------------------------------------------------------------------
select e.name as event, w.label as session,
       to_char(w.start_time, 'HH24:MI') as start_time,
       to_char(w.late_after, 'HH24:MI') as late_after,
       to_char(w.end_time,   'HH24:MI') as end_time,
       w.counts_as,
       to_regclass('public.attendance_corrections') is not null as new_table_exists,
       not has_table_privilege('anon', 'public.attendance_corrections', 'select')
         and not has_table_privilege('anon', 'public.work_hours', 'select')      as public_is_shut_out
from   event_windows w join events e on e.id = w.event_id
where  w.archived_at is null and e.archived_at is null
order  by e.name, w.start_time;
