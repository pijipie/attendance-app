-- =====================================================================
--  ATTENDANCE SYSTEM  -  07_window_counter.sql
--  The counter follows the SESSION, not the whole day (5 Oct 2026).
--
--  Paste this WHOLE file into Supabase > SQL Editor and press RUN (once).
--  Safe to run again.
--
--  Why: on the first pilot day the big screen said "5 present today" all
--  day. At check-out time (the "Petang" session) it did not start again
--  from 0, so nobody could tell whether check-out was being recorded.
--  (It was. Only the number was misleading.)
--
--  PART A : counter_for()    - picks the session to count, and counts it
--  PART B : display_poll()   - the big screen now gets that counter
--  PART C : event_counter()  - the same counter for the admin QR screen
--  PART D : check_in()       - one new line, so two overlapping sessions
--                              can never be picked at random
--  PART E : who may use which door
--
--  What does NOT change
--    * No table, no column, no row. Only functions.
--    * Who is accepted or refused at check-in. Today's sessions do not
--      overlap, so PART D changes nothing for them.
--    * The reply still has "present" and "total", so a big screen that
--      still runs the older page keeps working.
-- =====================================================================

begin;      -- all or nothing: if any part fails, nothing in this file is kept


-- =====================================================================
-- PART A : WHICH SESSION DOES THE COUNTER SHOW?
--   A "session" is one row of event_windows (for example Pagi, Petang).
--   Only sessions that apply TODAY are looked at: right weekday, inside
--   their start/end dates, not archived. That is the same "is it today"
--   test check_in() uses, without the clock part.
--
--   Among today's sessions, the first rule that finds one wins:
--     1. a session that is OPEN now
--        (if several are open: the one that started last)
--     2. else the session that FINISHED last
--        (so between sessions the screen keeps the result just reached)
--     3. else the NEXT session to open (early morning: it shows 0)
--   No session today at all (a weekend, say): the whole day is counted,
--   as before, and no session name is sent.
--
--   Example, Monday:  Pagi 03:00-07:40,  Petang 15:30-19:30
--     07:10  Pagi, open      counting up
--     10:00  Pagi, closed    stays at the last Pagi number
--     15:30  Petang, open    starts again from 0
--     20:00  Petang, closed  stays at the last Petang number
--
--   Rule 1 must agree with check_in() (PART D): the session the counter
--   shows while open is the session a check-in is written to.
--
--   An inside helper, like qr_token_for(): no page can call it directly.
-- =====================================================================
create or replace function counter_for(p_event_id uuid) returns jsonb
language plpgsql stable set search_path = public as $$
declare
  v_local  timestamp := now() at time zone 'Asia/Kuala_Lumpur';
  v_now    time      := v_local::time;
  v_window event_windows%rowtype;
begin
  select w.* into v_window
    from event_windows w
   where w.event_id = p_event_id
     and w.archived_at is null
     and (w.weekdays is null
          or extract(isodow from v_local)::smallint = any (w.weekdays))
     and (w.starts_on is null or v_local::date >= w.starts_on)
     and (w.ends_on   is null or v_local::date <= w.ends_on)
   order by
     -- which rule: 1 = open now, 2 = finished, 3 = not started yet
     case when v_now between w.start_time and w.end_time then 1
          when v_now > w.end_time                        then 2
          else                                                3 end,
     -- inside rule 1: started last.  inside rule 2: finished last.
     case when v_now between w.start_time and w.end_time then w.start_time
          when v_now > w.end_time                        then w.end_time end desc nulls last,
     -- inside rule 3: opens first
     w.start_time,
     w.id
   limit 1;

  return jsonb_build_object(
    'present', (select count(distinct a.staff_id) from attendance a
                 where a.event_id = p_event_id and a.status = 'present'
                   and a.attendance_date = v_local::date
                   and (v_window.id is null or a.window_id = v_window.id)),
    'total', (select count(*) from staff where active),
    'window_label', v_window.label,                       -- null when there is no session today
    'window_state', case when v_window.id is null                                  then null
                         when v_now between v_window.start_time and v_window.end_time then 'open'
                         when v_now > v_window.end_time                            then 'closed'
                         else                                                           'upcoming' end);
end;
$$;


-- =====================================================================
-- PART B : display_poll() version 3
--   Same as before up to the last step. The reply's "present" and "total"
--   now come from counter_for(), and two fields are new:
--     window_label : the session name, for example "Petang"
--     window_state : 'open', 'closed' or 'upcoming'
--   An older display page ignores the new fields and still works.
--   (The 5-minute pairing wait below also appears in display_register()
--   and display_approve(). Change all three together.)
-- =====================================================================
create or replace function display_poll(p_secret text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_display qr_displays%rowtype;
  v_event   events%rowtype;
  v_qr      jsonb;
begin
  if coalesce(length(p_secret), 0) not between 32 and 128 then
    return jsonb_build_object('state', 'unknown');
  end if;

  select * into v_display from qr_displays
   where secret_hash = encode(sha256(convert_to(p_secret, 'UTF8')), 'hex');
  if v_display.id is null then
    return jsonb_build_object('state', 'unknown');
  end if;
  if v_display.event_id is null then
    if v_display.created_at < now() - interval '5 minutes' then
      return jsonb_build_object('state', 'unknown');           -- the code ran out: ask for a new one
    end if;
    return jsonb_build_object('state', 'waiting', 'code', v_display.pair_code);
  end if;
  if v_display.stopped_at is not null or v_display.expires_at <= now() then
    return jsonb_build_object('state', 'ended');
  end if;

  select * into v_event from events
   where id = v_display.event_id and active and archived_at is null;
  if v_event.id is null then
    return jsonb_build_object('state', 'ended');
  end if;

  v_qr := qr_token_for(v_event.id);
  update qr_displays set last_seen_at = now() where id = v_display.id;

  return jsonb_build_object(
    'state', 'showing',
    'event_code', v_event.event_code,
    'event_name', v_event.name,
    'token', v_qr->>'token',
    'valid_seconds', (v_qr->>'valid_seconds')::integer,     -- seconds this token has LEFT
    'ends_at', v_display.expires_at)
    || counter_for(v_event.id);                             -- present, total, window_label, window_state
end;
$$;


-- =====================================================================
-- PART C : event_counter()
--   The admin QR screen used to count the whole day by itself, so it
--   would disagree with the big screen. Now it asks the database, and
--   both screens show the same number by the same rule.
--   Admins only (any level: an operator can already read attendance).
-- =====================================================================
create or replace function event_counter(p_event_code text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_event_id uuid;
begin
  if not is_admin() then
    raise exception 'not_admin' using errcode = '42501';
  end if;
  if coalesce(length(p_event_code), 0) not between 1 and 60 then
    raise exception 'unknown_event';
  end if;

  select id into v_event_id from events
   where lower(event_code) = lower(trim(p_event_code)) and active and archived_at is null;
  if v_event_id is null then
    raise exception 'unknown_event';
  end if;

  return counter_for(v_event_id);
end;
$$;


-- =====================================================================
-- PART D : check_in() version 4
--   Version 3 from 06_security_hardening.sql, word for word, plus ONE
--   line ("order by", marked NEW in 07). Before, when two sessions of the
--   same event were open at the same moment, the database was free to
--   pick either. Now it always picks the one that started last, which is
--   also the one the counter shows.
--   The "where" test above that line is untouched: it is still the same
--   test list_events() uses. Keep the two the same.
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
  select w.id into v_window_id
    from event_windows w
   where w.event_id = v_event.id
     and w.archived_at is null
     and (w.weekdays is null
          or extract(isodow from v_local)::smallint = any (w.weekdays))
     and (w.starts_on is null or v_local::date >= w.starts_on)
     and (w.ends_on   is null or v_local::date <= w.ends_on)
     and v_local::time between w.start_time and w.end_time
   order by w.start_time desc, w.id      -- NEW in 07: if two sessions are open at once, the one that started last
   limit 1;

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
             distance_m, radius_applied_m, device_id, status, reason)
      values (v_staff.id, v_event.id, v_window_id, p_lat, p_lng, p_accuracy,
              v_distance, v_event.radius_m, p_device_id,
              case when v_reason is null then 'present'::attendance_status
                   else 'rejected'::attendance_status end,
              v_reason);
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
                              'distance_m', round(v_distance::numeric, 1));
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
-- PART E : WHO MAY USE WHICH DOOR
--   Take the default "everyone may call it" away first, then give on purpose.
-- =====================================================================
revoke all on function counter_for(uuid)   from public, anon, authenticated;   -- inside helper: nobody
revoke all on function event_counter(text) from public, anon, authenticated;
revoke all on function display_poll(text)  from public, anon, authenticated;
revoke all on function check_in(text, text, double precision, double precision, real, text, text) from public, anon, authenticated;

-- staff phones and the big screen (no login)
grant execute on function check_in(text, text, double precision, double precision, real, text, text) to anon, authenticated;
grant execute on function display_poll(text) to anon, authenticated;

-- signed-in people. The function checks that they are an admin.
grant execute on function event_counter(text) to authenticated;

commit;


-- ---------------------------------------------------------------------
-- Quick check. You should see one row for each active event, with its
-- counter. For "Daily Attendance (Sekolah)" on a working day, window_label
-- is "Pagi" or "Petang" and present is that session's number only.
--   new_functions = 2 on every row.
-- ---------------------------------------------------------------------
select e.event_code, e.name,
       counter_for(e.id) as counter,
       (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public' and p.proname in ('counter_for', 'event_counter')) as new_functions
from   events e
where  e.active and e.archived_at is null
order  by e.name;
