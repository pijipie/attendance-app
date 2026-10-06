-- =====================================================================
--  ATTENDANCE SYSTEM  -  09_late_stamp.sql
--  Late check-ins are accepted and stamped "late" (5 Oct 2026).
--
--  Paste this WHOLE file into Supabase > SQL Editor and press RUN (once).
--  Safe to run again.
--
--  Why: working hours start at 07:40. Until now the morning session ended
--  at 07:40, so someone who arrived at 07:45 was simply refused and left
--  no usable record. The school wants that person recorded, and marked.
--
--  How it works
--    A session (one row of event_windows) gets one more, optional, time:
--    "late after". Three times now describe a session:
--        start_time  ......  late_after  ......  end_time
--        |--- on time ---------|--- late, still accepted ---|  refused after
--    Example for the morning session:  03:00 ... 07:40 ... 09:00
--        07:30     accepted, on time
--        07:40:59  accepted, on time   (the whole minute 07:40 is on time)
--        07:41     accepted, late 1 minute
--        08:15     accepted, late 35 minutes
--        09:01     refused: outside_time_window (stored as rejected, as before)
--    A session with no "late after" time works exactly as before.
--
--  PART A : two new columns
--  PART B : check_in()        - works out the minutes late and stores them
--  PART C : attendance_log    - the readable view shows the new column
--  PART D : who may use which door
--
--  What does NOT change
--    * No existing row is changed. Every session keeps "late after" empty
--      until an admin fills it in on the Events screen, so NOTHING behaves
--      differently right after this file is run.
--    * A late check-in is a normal accepted row (status 'present'): it is
--      counted by the counter, and the one-person / one-device rules apply
--      to it like any other.
--    * The time test shared with list_events() is untouched.
--
--  AFTER running this file (in the admin page, Events > the event > its hours):
--    set the morning session's End to 09:00 and "Late after" to 07:40.
-- =====================================================================

-- ---------------------------------------------------------------------
-- GUARD (added 6 Oct 2026). This file is OLDER than 10_work_hours.sql.
-- Every file except the newest checks first and stops without changing
-- anything, so an old file can never be run over newer work by mistake.
-- (The sign that 10 is installed: event_windows has a counts_as column.)
-- ---------------------------------------------------------------------
begin;      -- all or nothing: if any part fails, nothing in this file is kept
do $$
begin
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'event_windows' and column_name = 'counts_as') then
    raise exception 'STOP: 10_work_hours.sql is already installed. This older file is not needed again. Nothing was changed.';
  end if;
end $$;


-- =====================================================================
-- PART A : TWO NEW COLUMNS
--   event_windows.late_after  : the last minute that still counts as on
--                               time. Empty = this session has no "late".
--                               Must lie inside the session's own hours.
--   attendance.late_minutes   : how many minutes after that time the
--                               person checked in. Empty = on time.
--                               It is written once, at check-in, and kept:
--                               changing the session's times later does not
--                               rewrite history (the same idea as
--                               radius_applied_m).
--   Admins already hold the table rights they need (06, PART F): they can
--   edit event_windows and can only READ attendance. Nothing to grant.
-- =====================================================================
alter table event_windows add column if not exists late_after time;

alter table event_windows drop constraint if exists event_windows_late_after_check;
alter table event_windows add  constraint event_windows_late_after_check
  check (late_after is null or (late_after >= start_time and late_after < end_time));

alter table attendance add column if not exists late_minutes integer;

alter table attendance drop constraint if exists attendance_late_minutes_check;
alter table attendance add  constraint attendance_late_minutes_check
  check (late_minutes is null or (late_minutes > 0 and status = 'present'));


-- =====================================================================
-- PART B : check_in() version 5
--   Version 4 from 07_window_counter.sql, word for word, plus the lines
--   marked "NEW in 09":
--     * step 3 also reads the session's late_after time
--     * step 3a works out the minutes late
--     * step 5 stores them on an accepted row
--     * step 6 adds late, late_minutes and late_after to the reply,
--       only when the person is late
--   Nothing about WHO is accepted or refused is changed here. A session is
--   open from start_time to end_time exactly as before; an admin makes room
--   for late arrivals by moving end_time, not by anything in this function.
-- =====================================================================
create or replace function check_in(
  p_staff_code  text,
  p_event_code  text,
  p_lat         double precision,
  p_lng         double precision,
  p_accuracy    real,
  p_device_id   text,
  p_qr_token    text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_staff     staff%rowtype;
  v_event     events%rowtype;
  v_settings  org_settings%rowtype;
  v_local     timestamp := now() at time zone 'Asia/Kuala_Lumpur';
  v_window_id uuid;
  v_late_after time;                -- NEW in 09: the session's "late after" time, if it has one
  v_late_min   integer;             -- NEW in 09: minutes late. Stays empty when on time.
  v_distance  double precision;
  v_reason    text;
  v_keep      boolean := true;      -- false = answer, but do not store a row
begin
  -- 0. Size limits first, before anything is trimmed, searched or stored.
  if coalesce(length(p_staff_code), 0) not between 1 and 60
     or coalesce(length(p_event_code), 0) not between 1 and 60
     or coalesce(length(p_device_id), 0) not between 1 and 200
     or coalesce(length(p_qr_token), 0) > 64 then
    return jsonb_build_object('ok', false, 'reason', 'bad_input');
  end if;

  p_staff_code := trim(p_staff_code);
  p_event_code := trim(p_event_code);
  p_device_id  := trim(p_device_id);

  if length(p_staff_code) not between 1 and 20
     or length(p_event_code) not between 1 and 20
     or p_device_id !~ '^[A-Za-z0-9_.:-]{1,64}$'
     or p_lat is null or p_lng is null or p_accuracy is null
     or p_lat not between -90 and 90 or p_lng not between -180 and 180
     or not (p_accuracy >= 0 and p_accuracy < 'infinity'::real) then   -- refuses negative, infinite and "not a number"
    return jsonb_build_object('ok', false, 'reason', 'bad_input');
  end if;

  -- 1. who and where (case-insensitive codes; archived events do not count)
  select * into v_staff from staff
   where lower(staff_code) = lower(p_staff_code) and active;
  select * into v_event from events
   where lower(event_code) = lower(p_event_code) and active and archived_at is null;

  -- The list of events is public (the dropdown shows it), so saying
  -- "no such event" gives nothing away.
  if v_event.id is null then
    return jsonb_build_object('ok', false, 'reason', 'unknown_staff_or_event');
  end if;

  select * into v_settings from org_settings where id = 1;

  -- 2. distance from the event centre in metres (Haversine formula)
  v_distance := 2 * 6371000 * asin(least(1, sqrt(
        power(sin(radians(p_lat - v_event.latitude) / 2), 2)
      + cos(radians(v_event.latitude)) * cos(radians(p_lat))
        * power(sin(radians(p_lng - v_event.longitude) / 2), 2))));

  -- 3. is "now" inside one of this event's allowed windows?
  --    (list_events() uses the same test. Keep the two the same.)
  select w.id, w.late_after into v_window_id, v_late_after      -- NEW in 09: also read the late time
    from event_windows w
   where w.event_id = v_event.id
     and w.archived_at is null
     and (w.weekdays is null
          or extract(isodow from v_local)::smallint = any (w.weekdays))
     and (w.starts_on is null or v_local::date >= w.starts_on)
     and (w.ends_on   is null or v_local::date <= w.ends_on)
     and v_local::time between w.start_time and w.end_time
   order by w.start_time desc, w.id      -- if two sessions are open at once, the one that started last
   limit 1;

  -- 3a. NEW in 09: on time or late?
  --     The seconds are dropped first, so with "late after 07:40" a check-in
  --     at 07:40:59 is on time and 07:41:00 is 1 minute late.
  --     Late is NOT a refusal: the check-in is accepted and only stamped.
  if v_late_after is not null and date_trunc('minute', v_local)::time > v_late_after then
    v_late_min := (extract(epoch from (date_trunc('minute', v_local)::time - v_late_after)) / 60)::integer;
  end if;

  -- 4. first failed rule wins
  v_reason := case
    when v_event.require_qr and not exists (
           select 1 from qr_tokens t
            where t.event_id = v_event.id
              and t.token = p_qr_token
              and t.expires_at > now())             then 'qr_invalid_or_expired'
    when v_window_id is null                        then 'outside_time_window'
    when p_accuracy > v_settings.max_gps_accuracy_m then 'gps_accuracy_too_low'
    when v_distance > v_event.radius_m              then 'outside_geofence'
  end;

  -- 4a. An unknown staff code gets exactly the answer a real one would get
  --     at this point, and nothing is written. Only someone who passes
  --     every check above (QR, hours, GPS, distance) is told the code is wrong.
  if v_staff.id is null then
    if v_reason is null then
      return jsonb_build_object('ok', false, 'reason', 'unknown_staff_or_event');
    end if;
    return jsonb_build_object('ok', false, 'reason', v_reason)
        || case when v_reason = 'outside_geofence'
                then jsonb_build_object('distance_m', round(v_distance::numeric, 1))
                else '{}'::jsonb end;
  end if;

  -- 4b. everything passed, so check for a duplicate before writing
  if v_reason is null then
    if exists (select 1 from attendance a
                where a.status = 'present'
                  and a.window_id = v_window_id
                  and a.attendance_date = v_local::date
                  and a.staff_id = v_staff.id) then
      v_reason := 'already_checked_in';
    elsif exists (select 1 from attendance a
                   where a.status = 'present'
                     and a.window_id = v_window_id
                     and a.attendance_date = v_local::date
                     and a.device_id = p_device_id) then
      v_reason := 'device_already_used';
    end if;
  end if;

  -- 4c. the brake: after 10 stored refusals for this person in 10 minutes,
  --     stop storing. The phone still gets its answer.
  if v_reason is not null
     and (select count(*) from attendance a
           where a.staff_id = v_staff.id
             and a.status = 'rejected'
             and a.checked_in_at > now() - interval '10 minutes') >= 10 then
    v_keep := false;
  end if;

  -- 5. write the log row (accepted, or rejected as evidence)
  if v_keep then
    begin
      insert into attendance
            (staff_id, event_id, window_id, latitude, longitude, gps_accuracy_m,
             distance_m, radius_applied_m, device_id, status, reason, late_minutes)
      values (v_staff.id, v_event.id, v_window_id, p_lat, p_lng, p_accuracy,
              v_distance, v_event.radius_m, p_device_id,
              case when v_reason is null then 'present'::attendance_status
                   else 'rejected'::attendance_status end,
              v_reason,
              case when v_reason is null then v_late_min end);     -- NEW in 09: only an accepted row can be late
    exception
      when unique_violation then
        -- Two phones pressed Submit in the same split second and the other
        -- one won. Keep a row for this one too.
        v_reason := 'duplicate_same_moment';
        insert into attendance
              (staff_id, event_id, window_id, latitude, longitude, gps_accuracy_m,
               distance_m, radius_applied_m, device_id, status, reason)
        values (v_staff.id, v_event.id, v_window_id, p_lat, p_lng, p_accuracy,
                v_distance, v_event.radius_m, p_device_id, 'rejected', v_reason);
    end;
  end if;

  -- 6. tell the phone
  if v_reason is null then
    return jsonb_build_object('ok', true,
                              'name', v_staff.full_name,
                              'event', v_event.name,
                              'distance_m', round(v_distance::numeric, 1))
        -- NEW in 09: three extra fields, only when late. An older staff page ignores them.
        || case when v_late_min is not null
                then jsonb_build_object('late', true,
                                        'late_minutes', v_late_min,
                                        'late_after', to_char(v_late_after, 'HH24:MI'))
                else '{}'::jsonb end;
  end if;

  if v_reason in ('already_checked_in', 'device_already_used', 'duplicate_same_moment') then
    return jsonb_build_object('ok', false,
                              'reason', 'duplicate_or_device_already_used',
                              'detail', v_reason);
  end if;

  return jsonb_build_object('ok', false, 'reason', v_reason)
      || case when v_reason = 'outside_geofence'
              then jsonb_build_object('distance_m', round(v_distance::numeric, 1))
              else '{}'::jsonb end;
end;
$$;


-- =====================================================================
-- PART C : attendance_log
--   The readable view from 01_schema.sql, with one column added at the
--   end. (A view can only grow at the end; the first ten columns are
--   exactly as they were.)
-- =====================================================================
create or replace view attendance_log with (security_invoker = on) as
select  (a.checked_in_at at time zone 'Asia/Kuala_Lumpur') as local_time,
        s.staff_code,
        s.full_name,
        e.name        as event,
        w.label       as session,
        a.status,
        a.reason,
        a.distance_m,
        a.gps_accuracy_m,
        a.device_id,
        a.late_minutes                                    -- NEW in 09: empty = on time
from    attendance a
join    staff  s on s.id = a.staff_id
join    events e on e.id = a.event_id
left join event_windows w on w.id = a.window_id
order by a.checked_in_at desc;


-- =====================================================================
-- PART D : WHO MAY USE WHICH DOOR
--   Take the default "everyone may call it" away first, then give on purpose.
-- =====================================================================
revoke all on function check_in(text, text, double precision, double precision, real, text, text) from public, anon, authenticated;
grant execute on function check_in(text, text, double precision, double precision, real, text, text) to anon, authenticated;

revoke all   on attendance_log from anon, authenticated;
grant select on attendance_log to authenticated;       -- row-level security on the tables underneath still decides

commit;


-- ---------------------------------------------------------------------
-- Quick check. You should see one row for each session that is in use:
--   both_columns_exist = true on every row
--   late_after         = empty on every row, until you set it in the admin page
-- ---------------------------------------------------------------------
select e.name as event, w.label as session,
       to_char(w.start_time, 'HH24:MI') as start_time,
       to_char(w.late_after, 'HH24:MI') as late_after,
       to_char(w.end_time,   'HH24:MI') as end_time,
       (select count(*) = 2 from information_schema.columns
         where table_schema = 'public'
           and (table_name, column_name) in (('event_windows', 'late_after'), ('attendance', 'late_minutes'))) as both_columns_exist
from   event_windows w join events e on e.id = w.event_id
where  w.archived_at is null and e.archived_at is null
order  by e.name, w.start_time;
