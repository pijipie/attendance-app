-- =====================================================================
--  ATTENDANCE SYSTEM  -  12_location_switch_invited_staff.sql
--  Two new choices for an event (8 Oct 2026):
--    1. "Require location" can be switched off.
--    2. An event can be for selected staff only.
--
--  Paste this WHOLE file into Supabase > SQL Editor and press RUN (once).
--  Safe to run again.
--
--  1. REQUIRE LOCATION (on / off)
--     Until now every check-in needed a position inside the event's circle.
--     Some events only need a record that the person took part (an online
--     briefing, a course held somewhere else). Each event now has two
--     independent switches:
--         Require location   on = as before        off = no position asked
--         Require the QR     on = scan the code    off = no scan
--     With "Require location" off:
--       * the staff page does not ask for location at all;
--       * check_in() skips the accuracy and distance checks;
--       * NO position is stored, even if a phone sends one;
--       * the hours, the QR, "one person, one device" and the brake all
--         work exactly as before.
--     With both switches off, anyone who has the link can record attendance
--     from anywhere, during the event's hours. The admin page says so.
--     The event keeps its pin and radius while the switch is off, so
--     switching it back on restores them.
--
--  2. SELECTED STAFF
--     An event is for "All staff" (as now) or for "Selected staff". For the
--     second kind an admin ticks who is invited.
--       * "Not checked in" and the counter then use that list
--         ("4 of 12 submitted", not "4 of 70").
--       * A person who is NOT on the list can still check in. The check-in
--         is accepted, the row is marked not_listed, the person is told,
--         and the admin page shows the mark. Nobody is turned away at the
--         door; the admin decides afterwards.
--       * The staff page has no login, so the event still appears in
--         everyone's list of events. That cannot be hidden.
--
--  PART A : new columns
--  PART B : event_staff + set_event_staff()   - the list of invited staff
--  PART C : check_in()      - location only when asked; marks "not on the list"
--  PART D : list_events()   - tells the staff page about the two choices
--  PART E : counter_for()   - counts the list for a selected-staff event
--  PART F : who may use which door
--
--  What does NOT change
--    * Every existing event keeps "Require location" ON and "All staff",
--      so NOTHING behaves differently right after this file is run.
--    * No existing attendance row is changed.
--    * The time test shared by check_in() and list_events() is untouched.
--    * An older staff page keeps working: it always sends a position, which
--      a "location off" event simply ignores.
-- =====================================================================

begin;      -- all or nothing: if any part fails, nothing in this file is kept


-- =====================================================================
-- PART A : NEW COLUMNS
--   events.require_location  : true = a position inside the circle is needed
--   events.audience          : 'all' or 'selected'
--   attendance.not_listed    : true = accepted, but the person was not on
--                              the event's list at that moment
--   An event with location off does not need a pin, so latitude, longitude
--   and radius may now be empty - but only for such an event.
--   A check-in for such an event has no position, so the five position
--   columns of the attendance log may now be empty too.
-- =====================================================================
alter table events add column if not exists require_location boolean not null default true;
alter table events add column if not exists audience text not null default 'all';

alter table events drop constraint if exists events_audience_check;
alter table events add  constraint events_audience_check check (audience in ('all', 'selected'));

alter table events alter column latitude  drop not null;
alter table events alter column longitude drop not null;
alter table events alter column radius_m  drop not null;
alter table events drop constraint if exists events_location_check;
alter table events add  constraint events_location_check
  check (not require_location or (latitude is not null and longitude is not null and radius_m is not null));

alter table attendance alter column latitude         drop not null;
alter table attendance alter column longitude        drop not null;
alter table attendance alter column gps_accuracy_m   drop not null;
alter table attendance alter column distance_m       drop not null;
alter table attendance alter column radius_applied_m drop not null;
alter table attendance add column if not exists not_listed boolean not null default false;


-- =====================================================================
-- PART B : THE LIST OF INVITED STAFF
--   One row = "this person is invited to this event".
--   The list only matters while the event's audience is 'selected'. It is
--   kept when the event is switched back to 'all', so nothing is lost.
--   Admins read the table. They change it only through set_event_staff(),
--   which swaps the whole list in one go and writes ONE line in the
--   activity record (not one line per person).
-- =====================================================================
create table if not exists event_staff (
  event_id  uuid not null references events(id) on delete cascade,   -- an event that is really deleted takes its list with it
  staff_id  uuid not null references staff(id)  on delete cascade,
  added_at  timestamptz not null default now(),
  primary key (event_id, staff_id)
);
create index if not exists event_staff_staff_idx on event_staff (staff_id);

alter table event_staff enable row level security;
drop policy if exists admin_read on event_staff;
create policy admin_read on event_staff for select to authenticated using (is_admin());

-- Swap an event's list for the one given. Owner and manager only.
-- Answers {"added": n, "removed": n, "total": n}.
create or replace function set_event_staff(p_event_id uuid, p_staff_ids uuid[]) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_code    text;
  v_before  integer;
  v_added   text[];
  v_removed text[];
  v_total   integer;
begin
  if not can_manage() then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  if coalesce(array_length(p_staff_ids, 1), 0) > 2000 then
    raise exception 'too_many' using errcode = '22023';
  end if;
  select event_code into v_code from events where id = p_event_id;
  if v_code is null then
    raise exception 'unknown_event' using errcode = '22023';
  end if;

  lock table event_staff in share row exclusive mode;       -- two admins saving the same list at once: one after the other
  select count(*) into v_before from event_staff where event_id = p_event_id;

  with gone as (
    delete from event_staff es
     where es.event_id = p_event_id
       and not (es.staff_id = any (coalesce(p_staff_ids, '{}')))
    returning es.staff_id)
  select array_agg(s.staff_code order by s.staff_code) into v_removed
    from gone g join staff s on s.id = g.staff_id;

  with came as (
    insert into event_staff (event_id, staff_id)
    select p_event_id, s.id
      from staff s
     where s.id = any (coalesce(p_staff_ids, '{}'))          -- an ID that is not a staff member is simply left out
    on conflict do nothing
    returning staff_id)
  select array_agg(s.staff_code order by s.staff_code) into v_added
    from came c join staff s on s.id = c.staff_id;

  select count(*) into v_total from event_staff where event_id = p_event_id;

  -- One line in the activity record, in the same shape audit_row() uses for a change: "field: before -> after".
  if v_added is not null or v_removed is not null then
    insert into admin_audit (actor, actor_email, action, target, summary, detail)
    values (auth.uid(), (select email from auth.users where id = auth.uid()),
            'update', 'event_staff', v_code,
            jsonb_build_object('invited', jsonb_build_array(v_before, v_total))
            || case when v_added   is not null then jsonb_build_object('added',   jsonb_build_array(null, array_to_string(v_added, ', ')))   else '{}'::jsonb end
            || case when v_removed is not null then jsonb_build_object('removed', jsonb_build_array(array_to_string(v_removed, ', '), null)) else '{}'::jsonb end);
  end if;

  return jsonb_build_object('added', coalesce(array_length(v_added, 1), 0),
                            'removed', coalesce(array_length(v_removed, 1), 0),
                            'total', v_total);
end;
$$;


-- =====================================================================
-- PART C : check_in()
--   check_in() from 09_late_stamp.sql, word for word, plus the lines
--   marked "NEW in 12". Same seven inputs, so nothing that calls it changes.
--     * the three position numbers may now be empty (all three, or none)
--     * step 1a: a position is needed only when the event asks for one
--     * step 4 : accuracy and distance are checked only for such an event
--     * step 4a-2: is the person on the event's list?
--     * step 5 : the row carries not_listed; with no position the five
--                position columns stay empty
--     * step 6 : the answer says not_listed when that is so
--   One new answer: 'location_required' (a position was needed and none
--   was sent). Nothing is stored for it, whoever asks.
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
  v_late_after time;                -- the session's "late after" time, if it has one
  v_late_min   integer;             -- minutes late. Stays empty when on time.
  v_distance  double precision;
  v_reason    text;
  v_keep      boolean := true;      -- false = answer, but do not store a row
  v_listed    boolean := true;      -- NEW in 12: false = accepted, but the name is not on this event's list
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
     -- NEW in 12: a position is sent whole (all three numbers) or not at all.
     --            Whether one is NEEDED depends on the event, so that is asked in step 1a.
     or (p_lat is null) <> (p_lng is null) or (p_lat is null) <> (p_accuracy is null)
     or (p_lat is not null and (
              p_lat not between -90 and 90 or p_lng not between -180 and 180
           or not (p_accuracy >= 0 and p_accuracy < 'infinity'::real))) then   -- refuses negative, infinite and "not a number"
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

  -- 1a. NEW in 12: does this event ask for a position at all?
  --     "Require location" ON  : a position must have been sent. With none, the answer is
  --                              'location_required' and nothing is stored (the phone had nothing to measure;
  --                              the staff page reports that through report_location_problem()).
  --     "Require location" OFF : whatever the phone sent is thrown away here. It is not checked and not stored.
  if v_event.require_location then
    if p_lat is null then
      return jsonb_build_object('ok', false, 'reason', 'location_required');
    end if;
  else
    p_lat := null; p_lng := null; p_accuracy := null;
  end if;

  select * into v_settings from org_settings where id = 1;

  -- 2. distance from the event centre in metres (Haversine formula).
  --    NEW in 12: only when there is a position. Without one it stays empty.
  --    (It must be skipped, not just left to work itself out: least(1, nothing) is 1,
  --    which would come out as "half-way round the world".)
  if p_lat is not null then
    v_distance := 2 * 6371000 * asin(least(1, sqrt(
          power(sin(radians(p_lat - v_event.latitude) / 2), 2)
        + cos(radians(v_event.latitude)) * cos(radians(p_lat))
          * power(sin(radians(p_lng - v_event.longitude) / 2), 2))));
  end if;

  -- 3. is "now" inside one of this event's allowed windows?
  --    (list_events() uses the same test. Keep the two the same.)
  select w.id, w.late_after into v_window_id, v_late_after
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

  -- 3a. on time or late?
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
    when v_event.require_location and p_accuracy > v_settings.max_gps_accuracy_m then 'gps_accuracy_too_low'     -- NEW in 12: only when the event asks for a position
    when v_event.require_location and v_distance > v_event.radius_m              then 'outside_geofence'
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

  -- 4a-2. NEW in 12: is this person on the event's list?
  --       An event for "All staff" has no list: everyone is on it.
  --       An event for "Selected staff": a person who is not on the list is still ACCEPTED and recorded,
  --       and the row is marked not_listed. The mark is written once, like late_minutes: changing the
  --       list later does not rewrite history.
  v_listed := v_event.audience <> 'selected'
              or exists (select 1 from event_staff es where es.event_id = v_event.id and es.staff_id = v_staff.id);

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
             distance_m, radius_applied_m, device_id, status, reason, late_minutes, not_listed)       -- NEW in 12: not_listed
      values (v_staff.id, v_event.id, v_window_id, p_lat, p_lng, p_accuracy,
              v_distance, case when v_event.require_location then v_event.radius_m end, p_device_id,
              case when v_reason is null then 'present'::attendance_status
                   else 'rejected'::attendance_status end,
              v_reason,
              case when v_reason is null then v_late_min end,      -- only an accepted row can be late
              not v_listed);
    exception
      when unique_violation then
        -- Two phones pressed Submit in the same split second and the other
        -- one won. Keep a row for this one too.
        v_reason := 'duplicate_same_moment';
        insert into attendance
              (staff_id, event_id, window_id, latitude, longitude, gps_accuracy_m,
               distance_m, radius_applied_m, device_id, status, reason, not_listed)
        values (v_staff.id, v_event.id, v_window_id, p_lat, p_lng, p_accuracy,
                v_distance, case when v_event.require_location then v_event.radius_m end, p_device_id, 'rejected', v_reason, not v_listed);
    end;
  end if;

  -- 6. tell the phone
  if v_reason is null then
    return jsonb_build_object('ok', true,
                              'name', v_staff.full_name,
                              'event', v_event.name,
                              'distance_m', round(v_distance::numeric, 1))
        -- three extra fields, only when late
        || case when v_late_min is not null
                then jsonb_build_object('late', true,
                                        'late_minutes', v_late_min,
                                        'late_after', to_char(v_late_after, 'HH24:MI'))
                else '{}'::jsonb end
        -- NEW in 12: one extra field, only when the name is not on the event's list. An older staff page ignores it.
        || case when not v_listed then jsonb_build_object('not_listed', true) else '{}'::jsonb end;
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
-- PART D : list_events()
--   The same list as before, with two more facts for each event, so the
--   staff page knows not to look for the phone's position, and can say that
--   an event is for invited staff. Both are already plain to anyone who
--   uses the page, so nothing new is given away.
--   (The list of WHO is invited is not sent. It never leaves the admin page.)
--   A function's list of columns cannot be changed in place, so the old one
--   is dropped and made again inside this same all-or-nothing block: there
--   is no moment without it. The time test is the one check_in() uses.
-- =====================================================================
drop function if exists list_events();
create function list_events()
returns table (event_code text, name text, require_qr boolean, open_now boolean,
               require_location boolean, audience text)                       -- NEW in 12: the last two
language sql stable security definer set search_path = public as $$
  select e.event_code,
         e.name,
         e.require_qr,
         exists (
           select 1
             from event_windows w
            where w.event_id = e.id
              and w.archived_at is null
              and (w.weekdays is null
                   or extract(isodow from t.local_now)::smallint = any (w.weekdays))
              and (w.starts_on is null or t.local_now::date >= w.starts_on)
              and (w.ends_on   is null or t.local_now::date <= w.ends_on)
              and t.local_now::time between w.start_time and w.end_time
         ) as open_now,
         e.require_location,
         e.audience
    from events e
   cross join (select now() at time zone 'Asia/Kuala_Lumpur' as local_now) t
   where e.active and e.archived_at is null
   order by e.name;
$$;


-- =====================================================================
-- PART E : counter_for()
--   counter_for() from 07_window_counter.sql, word for word, plus the lines
--   marked "NEW in 12". The staff page, the big screen and the admin QR
--   screen all get their number from here, so all three follow.
--   For a selected-staff event: "present" counts the people on the list who
--   have checked in, and "total" is the size of the list.
-- =====================================================================
create or replace function counter_for(p_event_id uuid) returns jsonb
language plpgsql stable set search_path = public as $$
declare
  v_local  timestamp := now() at time zone 'Asia/Kuala_Lumpur';
  v_now    time      := v_local::time;
  v_window event_windows%rowtype;
  v_selected boolean;                 -- NEW in 12: true = this event is for selected staff only
begin
  select e.audience = 'selected' into v_selected from events e where e.id = p_event_id;
  v_selected := coalesce(v_selected, false);

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
                   and (v_window.id is null or a.window_id = v_window.id)
                   -- NEW in 12: for a selected-staff event, count only the people on its list,
                   --            so the screen can never say "13 of 12"
                   and (not v_selected or exists (select 1 from event_staff es
                                                   where es.event_id = p_event_id and es.staff_id = a.staff_id))),
    -- NEW in 12: "of how many" is the list for a selected-staff event, everyone otherwise
    'total', case when v_selected
                  then (select count(*) from event_staff es join staff s on s.id = es.staff_id
                         where es.event_id = p_event_id and s.active)
                  else (select count(*) from staff where active) end,
    'window_label', v_window.label,                       -- null when there is no session today
    'window_state', case when v_window.id is null                                  then null
                         when v_now between v_window.start_time and v_window.end_time then 'open'
                         when v_now > v_window.end_time                            then 'closed'
                         else                                                           'upcoming' end);
end;
$$;


-- =====================================================================
-- PART F : WHO MAY USE WHICH DOOR
--   Supabase gives everything on a new table to everyone by default.
--   Take it all away first, then give on purpose.
-- =====================================================================
revoke all   on event_staff from anon, authenticated;
grant select on event_staff to authenticated;            -- read only. Changes go through set_event_staff().

revoke all on function set_event_staff(uuid, uuid[]) from public, anon, authenticated;
grant execute on function set_event_staff(uuid, uuid[]) to authenticated;    -- the function itself still asks can_manage()

revoke all on function check_in(text, text, double precision, double precision, real, text, text) from public, anon, authenticated;
grant execute on function check_in(text, text, double precision, double precision, real, text, text) to anon, authenticated;

revoke all on function list_events() from public, anon, authenticated;
grant execute on function list_events() to anon, authenticated;

revoke all on function counter_for(uuid) from public, anon, authenticated;   -- inside helper: nobody calls it directly

commit;


-- ---------------------------------------------------------------------
-- Quick check. You should see one row for each event:
--   require_location = true   on every row (until you switch one off)
--   audience         = all    on every row (until you choose "Selected staff")
--   invited          = 0
--   new_parts_exist  = true
--   public_is_shut_out = true
-- ---------------------------------------------------------------------
select e.name as event,
       e.require_location,
       e.audience,
       (select count(*) from event_staff es where es.event_id = e.id) as invited,
       to_regclass('public.event_staff') is not null
         and exists (select 1 from information_schema.columns
                      where table_schema = 'public' and table_name = 'attendance' and column_name = 'not_listed') as new_parts_exist,
       not has_table_privilege('anon', 'public.event_staff', 'select')
         and not has_function_privilege('anon', 'public.set_event_staff(uuid, uuid[])', 'execute')             as public_is_shut_out
from   events e
where  e.archived_at is null
order  by e.name;
