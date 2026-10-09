-- =====================================================================
--  ATTENDANCE SYSTEM  -  13_work_exits.sql
--  "Keluar waktu bekerja": stepping out during working hours (8 Oct 2026).
--
--  Paste this WHOLE file into Supabase > SQL Editor and press RUN (once).
--  Safe to run again. Needs file 12 first.
--
--  Why: staff leave the school during working hours (to the bank, the
--  clinic, to fetch a child) and today that is written in a paper book,
--  apart from the attendance record. The school's rule: no more than
--  4 hours away in one working day; more than that is dealt with under the
--  school's leave rules.
--
--  How it works
--    An admin switches "Allow keluar waktu bekerja" on for an event (the
--    daily attendance). The staff page then offers "Keluar waktu bekerja"
--    for that event, with the event's own pin, radius and working hours.
--
--    LEAVING (Keluar), at the school, during working hours:
--      * the person must have checked in that morning;
--      * they write their own reason, and the time they will be back;
--      * the page shows the latest time allowed: now + what is left of the
--        4 hours today, and never later than the end of the working day;
--      * a later time is REFUSED, with the latest allowed time in the answer;
--      * or they tick "Not coming back today" (pulang). That is always
--        recorded, it is the day's check-out, and if it uses more than
--        what is left of the 4 hours it is marked "over 4 hours".
--
--    COMING BACK (Masuk semula), at the school: closes the outing. Coming
--    back after the time they wrote is recorded, and marked late.
--
--    FORGETTING to press Masuk semula: after the written time the outing
--    shows as "overdue". An owner or manager can enter the time of return
--    by hand, with a reason, or mark "did not come back".
--
--  Working hours are the ones the hours list already uses: from the
--  check-in session's "late after" time to the time the check-out session
--  opens (7.40 to 15.30; Friday 7.40 to 12.00). An event without those
--  two sessions cannot allow outings.
--
--  PART A : events.allow_exit
--  PART B : work_exits                 - one row per outing
--  PART C : work_day_of()              - an event's working hours on a date
--  PART D : exit_rules()               - the hint on the staff page
--  PART E : work_exit()                - the door for staff phones
--  PART F : exit_set_return()          - the admin's manual return
--  PART G : work_exit_log              - what the admin page reads
--  PART H : work_hours                 - going home counts as check-out
--  PART I : list_events()              - tells the page which events allow it
--  PART J : remove_event()             - learns about the new table
--  PART K : who may use which door
--
--  What does NOT change
--    * Every event keeps "Allow keluar waktu bekerja" OFF, so NOTHING
--      behaves differently right after this file is run.
--    * check_in(), the counter and the display page are not touched.
--    * Official duty outside the school is NOT an outing: it is its own event.
--
--  The 4-hour limit (240 minutes) is written in three places: work_exit(),
--  exit_rules() and work_exit_log. Change all three together.
-- =====================================================================

begin;      -- all or nothing: if any part fails, nothing in this file is kept

do $$
begin
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'events' and column_name = 'require_location') then
    raise exception 'STOP: run 12_location_switch_invited_staff.sql first. Nothing was changed.';
  end if;
  if coalesce(obj_description('public.counter_for(uuid)'::regprocedure, 'pg_proc'), '') like '%14_counter_active_staff%' then
    raise exception 'STOP: 14_counter_active_staff.sql is already installed. This older file is not needed again. Nothing was changed.';
  end if;
end $$;


-- =====================================================================
-- PART A : THE SWITCH ON AN EVENT
-- =====================================================================
alter table events add column if not exists allow_exit boolean not null default false;


-- =====================================================================
-- PART B : ONE ROW PER OUTING
--   Rows are only ever written by the functions below. Nobody can edit or
--   delete them from the admin page, like the attendance log.
--   At most one outing is open (no return yet) per person and day; going
--   home stays open for good, so nothing more can follow it that day.
-- =====================================================================
create table if not exists work_exits (
  id                     uuid primary key default gen_random_uuid(),
  staff_id               uuid not null references staff(id),
  event_id               uuid not null references events(id),
  exit_date              date not null,                                  -- the Malaysian date
  out_at                 timestamptz not null default now(),
  reason                 text not null check (length(btrim(reason)) between 2 and 200),
  going_home             boolean not null default false,                 -- "not coming back today"
  planned_back           time,                                           -- the time the person wrote
  back_at                timestamptz,
  back_source            text check (back_source in ('recorded', 'manual')),
  back_note              text check (back_note is null or length(btrim(back_note)) between 3 and 200),
  back_entered_by        uuid,
  back_entered_by_email  text,
  out_device             text not null check (length(out_device) between 1 and 64),
  back_device            text check (back_device is null or length(back_device) between 1 and 64),
  out_lat                double precision,
  out_lng                double precision,
  out_accuracy           real,
  out_distance           real,
  back_lat               double precision,
  back_lng               double precision,
  back_accuracy          real,
  back_distance          real,
  check (going_home or planned_back is not null),
  check (not (going_home and back_at is not null))
);
create unique index if not exists work_exits_one_open on work_exits (staff_id, exit_date) where back_at is null;
create index if not exists work_exits_day_idx on work_exits (exit_date, event_id, out_at);

alter table work_exits enable row level security;
drop policy if exists admin_read on work_exits;
create policy admin_read on work_exits for select to authenticated using (is_admin());


-- =====================================================================
-- PART C : AN EVENT'S WORKING HOURS ON A DATE
--   From the check-in session's "late after" time to the start of the
--   check-out session: the same rule the hours list uses (file 10).
--   Empty when the event has no such sessions that day (a weekend).
-- =====================================================================
create or replace function work_day_of(p_event_id uuid, p_date date)
returns table (work_start time, work_end time)
language sql stable set search_path = public as $$
  select (select w.late_after from event_windows w
           where w.event_id = p_event_id and w.counts_as = 'in' and w.archived_at is null
             and (w.weekdays is null or extract(isodow from p_date)::smallint = any (w.weekdays))
             and (w.starts_on is null or p_date >= w.starts_on)
             and (w.ends_on   is null or p_date <= w.ends_on)
           order by w.start_time, w.id limit 1),
         (select w.start_time from event_windows w
           where w.event_id = p_event_id and w.counts_as = 'out' and w.archived_at is null
             and (w.weekdays is null or extract(isodow from p_date)::smallint = any (w.weekdays))
             and (w.starts_on is null or p_date >= w.starts_on)
             and (w.ends_on   is null or p_date <= w.ends_on)
           order by w.start_time desc, w.id limit 1);
$$;


-- =====================================================================
-- PART D : THE HINT ON THE STAFF PAGE
--   Public, no login. Only the event's working hours today, the limit,
--   the time now and the latest return for someone who has not been out
--   yet today: nothing about any person. (Each person's own latest time
--   comes back from work_exit() when they ask for a later one.)
--   The time comes from the database, so a phone with a wrong clock still
--   shows the right "latest".
-- =====================================================================
create or replace function exit_rules(p_event_code text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_event  events%rowtype;
  v_start  time;
  v_end    time;
  v_minute time := date_trunc('minute', now() at time zone 'Asia/Kuala_Lumpur')::time;
begin
  if coalesce(length(p_event_code), 0) not between 1 and 60 then
    return jsonb_build_object('ok', false);
  end if;
  select * into v_event from events
   where lower(event_code) = lower(trim(p_event_code)) and active and archived_at is null and allow_exit;
  if v_event.id is null then
    return jsonb_build_object('ok', false);
  end if;
  select d.work_start, d.work_end into v_start, v_end
    from work_day_of(v_event.id, (now() at time zone 'Asia/Kuala_Lumpur')::date) d;
  if v_start is null or v_end is null then
    return jsonb_build_object('ok', false);
  end if;
  return jsonb_build_object('ok', true,
                            'limit_minutes', 240,          -- the same 240 as in work_exit()
                            'work_start', to_char(v_start, 'HH24:MI'),
                            'work_end',   to_char(v_end,   'HH24:MI'),
                            'now',        to_char(v_minute, 'HH24:MI'),
                            'open_now',   v_minute >= v_start and v_minute < v_end,
                            'latest',     case when v_minute >= v_start and v_minute < v_end
                                               then to_char(least(v_minute + interval '240 minutes', v_end), 'HH24:MI') end);
end;
$$;


-- =====================================================================
-- PART E : THE DOOR FOR STAFF PHONES
--   work_exit('out',  code, event, lat, lng, accuracy, device, reason, 'HH:MM', false)  leaving, coming back at HH:MM
--   work_exit('out',  code, event, lat, lng, accuracy, device, reason, null,    true)   leaving, not coming back today
--   work_exit('back', code, event, lat, lng, accuracy, device)                            back at school
--   The same rules as check_in() about sizes, the location and an unknown
--   staff code (same answer, nothing stored). Refused attempts are not
--   stored: nothing about the person has happened yet.
-- =====================================================================
create or replace function work_exit(
  p_action      text,
  p_staff_code  text,
  p_event_code  text,
  p_lat         double precision,
  p_lng         double precision,
  p_accuracy    real,
  p_device_id   text,
  p_reason      text    default null,
  p_back_time   text    default null,
  p_going_home  boolean default false
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  c_limit     constant integer := 240;      -- minutes away allowed in one working day (4 hours). Also in exit_rules() and work_exit_log.
  c_most      constant integer := 20;       -- a brake: outings one person can record in a day
  v_staff     staff%rowtype;
  v_event     events%rowtype;
  v_settings  org_settings%rowtype;
  v_today     date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
  v_minute    time := date_trunc('minute', now() at time zone 'Asia/Kuala_Lumpur')::time;
  v_start     time;
  v_end       time;
  v_distance  double precision;
  v_used      integer;
  v_left      integer;
  v_latest    time;
  v_back      time;
  v_open      work_exits%rowtype;
  v_away      integer;
  v_late      integer;
begin
  -- 0. Size limits first, then the shape of every input.
  if coalesce(length(p_action), 0) not between 1 and 10
     or coalesce(length(p_staff_code), 0) not between 1 and 60
     or coalesce(length(p_event_code), 0) not between 1 and 60
     or coalesce(length(p_device_id), 0) not between 1 and 200
     or coalesce(length(p_reason), 0) > 400
     or coalesce(length(p_back_time), 0) > 10 then
    return jsonb_build_object('ok', false, 'reason', 'bad_input');
  end if;

  p_staff_code := trim(p_staff_code);
  p_event_code := trim(p_event_code);
  p_device_id  := trim(p_device_id);
  p_reason     := nullif(btrim(p_reason), '');
  p_back_time  := nullif(btrim(p_back_time), '');
  p_going_home := coalesce(p_going_home, false);

  if p_action not in ('out', 'back')
     or length(p_staff_code) not between 1 and 20
     or length(p_event_code) not between 1 and 20
     or p_device_id !~ '^[A-Za-z0-9_.:-]{1,64}$'
     or (p_lat is null) <> (p_lng is null) or (p_lat is null) <> (p_accuracy is null)
     or (p_lat is not null and (
              p_lat not between -90 and 90 or p_lng not between -180 and 180
           or not (p_accuracy >= 0 and p_accuracy < 'infinity'::real)))
     or (p_back_time is not null and p_back_time !~ '^([01]?[0-9]|2[0-3]):[0-5][0-9]$') then
    return jsonb_build_object('ok', false, 'reason', 'bad_input');
  end if;

  -- 1. The event, and whether it allows outings at all. (The list of events is public.)
  select * into v_event from events
   where lower(event_code) = lower(p_event_code) and active and archived_at is null;
  if v_event.id is null or not v_event.allow_exit then
    return jsonb_build_object('ok', false, 'reason', 'exit_not_allowed');
  end if;
  select * into v_staff from staff where lower(staff_code) = lower(p_staff_code) and active;

  -- 2. Where: the event's own location rules, exactly as check_in() applies them.
  if v_event.require_location then
    if p_lat is null then
      return jsonb_build_object('ok', false, 'reason', 'location_required');
    end if;
    select * into v_settings from org_settings where id = 1;
    v_distance := 2 * 6371000 * asin(least(1, sqrt(
          power(sin(radians(p_lat - v_event.latitude) / 2), 2)
        + cos(radians(v_event.latitude)) * cos(radians(p_lat))
          * power(sin(radians(p_lng - v_event.longitude) / 2), 2))));
    if p_accuracy > v_settings.max_gps_accuracy_m then
      return jsonb_build_object('ok', false, 'reason', 'gps_accuracy_too_low');
    end if;
    if v_distance > v_event.radius_m then
      return jsonb_build_object('ok', false, 'reason', 'outside_geofence', 'distance_m', round(v_distance::numeric, 1));
    end if;
  else
    p_lat := null; p_lng := null; p_accuracy := null;
  end if;

  -- 3. When: leaving is only possible inside today's working hours.
  select d.work_start, d.work_end into v_start, v_end from work_day_of(v_event.id, v_today) d;
  if p_action = 'out' and (v_start is null or v_end is null or v_minute < v_start or v_minute >= v_end) then
    return jsonb_build_object('ok', false, 'reason', 'outside_work_hours',
                              'work_start', to_char(v_start, 'HH24:MI'), 'work_end', to_char(v_end, 'HH24:MI'));
  end if;

  -- 4. An unknown staff code gets this answer only now, after the checks anyone would face, and nothing is stored.
  if v_staff.id is null then
    return jsonb_build_object('ok', false, 'reason', 'unknown_staff_or_event');
  end if;

  -- 5. One request at a time for this person, so two quick presses cannot both pass.
  perform pg_advisory_xact_lock(hashtext('work_exit:' || v_staff.id::text));

  select coalesce(sum(greatest(0, extract(epoch from date_trunc('minute', x.back_at) - date_trunc('minute', x.out_at)) / 60)), 0)::integer
    into v_used
    from work_exits x
   where x.staff_id = v_staff.id and x.exit_date = v_today and x.back_at is not null;

  select * into v_open from work_exits x
   where x.staff_id = v_staff.id and x.exit_date = v_today and x.back_at is null
   limit 1;

  -- ---------------------------------------------------------------- LEAVING
  if p_action = 'out' then
    if not exists (select 1 from attendance a
                     left join event_windows w on w.id = a.window_id
                    where a.staff_id = v_staff.id and a.event_id = v_event.id
                      and a.attendance_date = v_today and a.status = 'present'
                      and coalesce(w.counts_as, 'in') = 'in') then
      return jsonb_build_object('ok', false, 'reason', 'not_checked_in');
    end if;
    if v_open.id is not null then
      if v_open.going_home then
        return jsonb_build_object('ok', false, 'reason', 'already_gone_home');
      end if;
      return jsonb_build_object('ok', false, 'reason', 'already_out', 'back_by', to_char(v_open.planned_back, 'HH24:MI'));
    end if;
    if p_reason is null or length(p_reason) < 2 then
      return jsonb_build_object('ok', false, 'reason', 'reason_needed');
    end if;
    if length(p_reason) > 200 then
      return jsonb_build_object('ok', false, 'reason', 'reason_too_long');
    end if;
    if exists (select 1 from work_exits x
                where x.exit_date = v_today and x.out_device = p_device_id and x.staff_id <> v_staff.id) then
      return jsonb_build_object('ok', false, 'reason', 'device_already_used');
    end if;
    if (select count(*) from work_exits x where x.staff_id = v_staff.id and x.exit_date = v_today) >= c_most then
      return jsonb_build_object('ok', false, 'reason', 'too_many');
    end if;

    v_left   := c_limit - v_used;
    v_latest := least(v_minute + make_interval(mins => greatest(v_left, 0)), v_end);   -- v_minute is before v_end, so this never runs past midnight

    if p_going_home then
      insert into work_exits (staff_id, event_id, exit_date, reason, going_home, planned_back,
                              out_device, out_lat, out_lng, out_accuracy, out_distance)
      values (v_staff.id, v_event.id, v_today, p_reason, true, null,
              p_device_id, p_lat, p_lng, p_accuracy, v_distance);
      v_away := (extract(epoch from v_end - v_minute) / 60)::integer;
      return jsonb_build_object('ok', true, 'action', 'out', 'going_home', true,
                                'name', v_staff.full_name, 'at', to_char(v_minute, 'HH24:MI'),
                                'over_limit', v_used + v_away > c_limit);
    end if;

    if v_left <= 0 then
      return jsonb_build_object('ok', false, 'reason', 'limit_used_up');
    end if;
    if p_back_time is null then
      return jsonb_build_object('ok', false, 'reason', 'time_needed', 'latest', to_char(v_latest, 'HH24:MI'));
    end if;
    v_back := p_back_time::time;
    if v_back <= v_minute then
      return jsonb_build_object('ok', false, 'reason', 'time_in_past', 'latest', to_char(v_latest, 'HH24:MI'));
    end if;
    if v_back > v_latest then
      return jsonb_build_object('ok', false, 'reason', 'return_too_late',
                                'latest', to_char(v_latest, 'HH24:MI'), 'minutes_left', v_left);
    end if;

    begin
      insert into work_exits (staff_id, event_id, exit_date, reason, going_home, planned_back,
                              out_device, out_lat, out_lng, out_accuracy, out_distance)
      values (v_staff.id, v_event.id, v_today, p_reason, false, v_back,
              p_device_id, p_lat, p_lng, p_accuracy, v_distance);
    exception when unique_violation then
      return jsonb_build_object('ok', false, 'reason', 'already_out');
    end;
    return jsonb_build_object('ok', true, 'action', 'out', 'going_home', false,
                              'name', v_staff.full_name, 'back_by', to_char(v_back, 'HH24:MI'));
  end if;

  -- ---------------------------------------------------------------- COMING BACK
  if v_open.id is null then
    return jsonb_build_object('ok', false, 'reason', 'no_open_exit');
  end if;
  if v_open.going_home then
    return jsonb_build_object('ok', false, 'reason', 'already_gone_home');
  end if;

  update work_exits
     set back_at = now(), back_source = 'recorded', back_device = p_device_id,
         back_lat = p_lat, back_lng = p_lng, back_accuracy = p_accuracy, back_distance = v_distance
   where id = v_open.id;

  v_away := greatest(0, (extract(epoch from date_trunc('minute', now()) - date_trunc('minute', v_open.out_at)) / 60)::integer);
  v_late := case when v_minute > v_open.planned_back
                 then (extract(epoch from v_minute - v_open.planned_back) / 60)::integer end;
  return jsonb_build_object('ok', true, 'action', 'back',
                            'name', v_staff.full_name,
                            'away_minutes', v_away,
                            'late_minutes', v_late,
                            'day_minutes', v_used + v_away,
                            'over_limit', v_used + v_away > c_limit);
end;
$$;


-- =====================================================================
-- PART F : THE ADMIN'S MANUAL RETURN
--   For an outing still open (the person forgot Masuk semula, or never came
--   back). Owner and manager only. Either the time of return, or "did not
--   come back" (it then counts as going home). Always with a reason, and
--   one line in the activity record.
--   exit_set_return(outing, 'HH:MM', reason, false)   came back at HH:MM
--   exit_set_return(outing, null,    reason, true)    did not come back
-- =====================================================================
create or replace function exit_set_return(p_exit_id uuid, p_time text, p_reason text, p_went_home boolean default false)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_exit   work_exits%rowtype;
  v_code   text;
  v_time   time;
  v_now    timestamp := now() at time zone 'Asia/Kuala_Lumpur';
begin
  if not can_manage() then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  if coalesce(length(btrim(p_reason)), 0) not between 3 and 200 or coalesce(length(p_time), 0) > 10 then
    return jsonb_build_object('ok', false, 'reason', 'bad_input');
  end if;
  select * into v_exit from work_exits where id = p_exit_id for update;
  if v_exit.id is null or v_exit.back_at is not null or v_exit.going_home then
    return jsonb_build_object('ok', false, 'reason', 'not_open');
  end if;
  select staff_code into v_code from staff where id = v_exit.staff_id;

  if coalesce(p_went_home, false) then
    update work_exits
       set going_home = true, back_source = 'manual', back_note = btrim(p_reason),
           back_entered_by = auth.uid(), back_entered_by_email = (select email from auth.users where id = auth.uid())
     where id = v_exit.id;
    insert into admin_audit (actor, actor_email, action, target, summary, detail)
    values (auth.uid(), (select email from auth.users where id = auth.uid()), 'update', 'work_exits',
            v_code || ' ' || v_exit.exit_date,
            jsonb_build_object('went_home', jsonb_build_array(false, true), 'note', jsonb_build_array(null, btrim(p_reason))));
    return jsonb_build_object('ok', true);
  end if;

  if p_time is null or p_time !~ '^([01]?[0-9]|2[0-3]):[0-5][0-9]$' then
    return jsonb_build_object('ok', false, 'reason', 'bad_input');
  end if;
  v_time := p_time::time;
  if v_time < date_trunc('minute', v_exit.out_at at time zone 'Asia/Kuala_Lumpur')::time then
    return jsonb_build_object('ok', false, 'reason', 'before_out');
  end if;
  if v_exit.exit_date + v_time > v_now then
    return jsonb_build_object('ok', false, 'reason', 'in_future');
  end if;
  update work_exits
     set back_at = (v_exit.exit_date + v_time) at time zone 'Asia/Kuala_Lumpur', back_source = 'manual',
         back_note = btrim(p_reason),
         back_entered_by = auth.uid(), back_entered_by_email = (select email from auth.users where id = auth.uid())
   where id = v_exit.id;
  insert into admin_audit (actor, actor_email, action, target, summary, detail)
  values (auth.uid(), (select email from auth.users where id = auth.uid()), 'update', 'work_exits',
          v_code || ' ' || v_exit.exit_date,
          jsonb_build_object('back', jsonb_build_array(null, to_char(v_time, 'HH24:MI')), 'note', jsonb_build_array(null, btrim(p_reason))));
  return jsonb_build_object('ok', true);
end;
$$;


-- =====================================================================
-- PART G : work_exit_log  - what the admin page reads
--   One row per outing, with the sums worked out here, never in the page.
--     minutes_away  back - out; for going home: end of working day - out;
--                   still open: empty
--     late_minutes  came back after the time written
--     day_minutes   all outings of that person that day
--     over_limit    day_minutes above 240 (4 hours)
--     status        back | out (not due yet) | overdue | gone_home
--   Seconds are dropped first, like "late" and the hours list.
-- =====================================================================
create or replace view work_exit_log with (security_invoker = on) as
with x as (
  select e.*, d.work_end,
         date_trunc('minute', e.out_at  at time zone 'Asia/Kuala_Lumpur') as out_local,
         date_trunc('minute', e.back_at at time zone 'Asia/Kuala_Lumpur') as back_local
    from work_exits e
    left join lateral work_day_of(e.event_id, e.exit_date) d on true
),
m as (
  select x.*,
         case when x.back_at is not null
              then greatest(0, extract(epoch from x.back_local - x.out_local) / 60)::integer
              when x.going_home and x.work_end is not null
              then greatest(0, extract(epoch from (x.exit_date + x.work_end) - x.out_local) / 60)::integer
         end as minutes_away
    from x
)
select  m.id,
        m.exit_date,
        m.event_id,
        m.staff_id,
        s.staff_code,
        s.full_name,
        m.out_at,
        m.reason,
        m.going_home,
        m.planned_back,
        m.back_at,
        m.back_source,
        m.back_note,
        m.back_entered_by_email,
        m.minutes_away,
        case when m.back_local is not null and m.planned_back is not null and m.back_local::time > m.planned_back
             then (extract(epoch from m.back_local::time - m.planned_back) / 60)::integer end as late_minutes,
        coalesce(sum(m.minutes_away) over (partition by m.staff_id, m.exit_date), 0)::integer       as day_minutes,
        coalesce(sum(m.minutes_away) over (partition by m.staff_id, m.exit_date), 0) > 240           as over_limit,
        case when m.going_home     then 'gone_home'
             when m.back_at is not null then 'back'
             when m.exit_date < (now() at time zone 'Asia/Kuala_Lumpur')::date
               or (now() at time zone 'Asia/Kuala_Lumpur')::time > m.planned_back then 'overdue'
             else 'out' end as status,
        m.work_end
from    m
join    staff s on s.id = m.staff_id;


-- =====================================================================
-- PART H : work_hours
--   The view from 10_work_hours.sql, word for word, plus the lines marked
--   "NEW in 13": someone who goes home during working hours has that time
--   as the day's check-out, shown with the source 'exit'. A recorded
--   check-out still wins; a manual time comes last.
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
  union all
  -- NEW in 13: going home during working hours ("pulang") is the day's check-out
  select x.staff_id, x.event_id, x.exit_date, 'out',
         'exit'::text, x.out_at, null::uuid, null::integer,
         null::text, null::text, null::uuid
    from work_exits x
   where x.going_home
),
pick as not materialized (
  -- one row per person, event, day and half
  select distinct on (staff_id, event_id, work_date, half) *
    from halves
   order by staff_id, event_id, work_date, half,
            case source when 'recorded' then 0 when 'exit' then 1 else 2 end,   -- recorded first, then "went home" (NEW in 13), then manual
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
-- PART I : list_events()
--   The list from 12, with one more fact for each event: whether it allows
--   outings, so the staff page can offer "Keluar waktu bekerja". Dropped and
--   made again inside this same all-or-nothing block, as in 12.
-- =====================================================================
drop function if exists list_events();
create function list_events()
returns table (event_code text, name text, require_qr boolean, open_now boolean,
               require_location boolean, audience text,
               allow_exit boolean)                                            -- NEW in 13: the last one
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
         e.audience,
         e.allow_exit
    from events e
   cross join (select now() at time zone 'Asia/Kuala_Lumpur' as local_now) t
   where e.active and e.archived_at is null
   order by e.name;
$$;


-- =====================================================================
-- PART J : remove_event()
--   remove_event() from 11, word for word, plus the line marked "NEW in 13":
--   an event with outings on record is archived, not deleted.
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
     or exists (select 1 from location_problems where event_id = p_event_id)
     or exists (select 1 from work_exits where event_id = p_event_id) then                  -- NEW in 13
    update events set archived_at = coalesce(archived_at, now()), active = false where id = p_event_id;
    return 'archived';
  end if;
  delete from events where id = p_event_id;      -- its hours go with it
  return 'deleted';
end;
$$;

-- =====================================================================
-- PART K : WHO MAY USE WHICH DOOR
--   Supabase gives everything on a new table to everyone by default.
--   Take it all away first, then give on purpose.
-- =====================================================================
revoke all   on work_exits from anon, authenticated;
grant select on work_exits to authenticated;                -- read only, and row-level security still asks is_admin()
revoke all   on work_exit_log from anon, authenticated;
grant select on work_exit_log to authenticated;
revoke all   on work_hours from anon, authenticated;
grant select on work_hours to authenticated;

revoke all on function work_day_of(uuid, date) from public, anon, authenticated;
grant execute on function work_day_of(uuid, date) to authenticated;                     -- the admin's view uses it; it only returns two times
revoke all on function exit_rules(text) from public, anon, authenticated;
grant execute on function exit_rules(text) to anon, authenticated;                       -- staff phones: working hours and the limit only
revoke all on function work_exit(text, text, text, double precision, double precision, real, text, text, text, boolean) from public, anon, authenticated;
grant execute on function work_exit(text, text, text, double precision, double precision, real, text, text, text, boolean) to anon, authenticated;
revoke all on function exit_set_return(uuid, text, text, boolean) from public, anon, authenticated;
grant execute on function exit_set_return(uuid, text, text, boolean) to authenticated;  -- the function itself still asks can_manage()
revoke all on function list_events() from public, anon, authenticated;
grant execute on function list_events() to anon, authenticated;
revoke all on function remove_event(uuid) from public, anon, authenticated;
grant execute on function remove_event(uuid) to authenticated;

commit;


-- ---------------------------------------------------------------------
-- Quick check. You should see one row for each event:
--   allow_exit         = false on every row (until you switch it on)
--   working_hours      = for the daily event, today's start and end (empty on a weekend)
--   new_parts_exist    = true
--   public_is_shut_out = true
-- ---------------------------------------------------------------------
select e.name as event,
       e.allow_exit,
       (select to_char(d.work_start, 'HH24:MI') || ' - ' || to_char(d.work_end, 'HH24:MI')
          from work_day_of(e.id, (now() at time zone 'Asia/Kuala_Lumpur')::date) d) as working_hours,
       to_regclass('public.work_exits') is not null and to_regclass('public.work_exit_log') is not null as new_parts_exist,
       not has_table_privilege('anon', 'public.work_exits', 'select')
         and not has_table_privilege('anon', 'public.work_exit_log', 'select')                  as public_is_shut_out
from   events e
where  e.archived_at is null
order  by e.name;
