-- =====================================================================
--  ATTENDANCE SYSTEM  -  15_step_out_time_left.sql
--  Stepping out: the midnight fix, and "time left today" (12 Oct 2026).
--
--  Paste this WHOLE file into Supabase > SQL Editor and press RUN (once).
--  Safe to run again. Needs file 14 first.
--
--  1. THE MIDNIGHT FIX
--     The latest return time was worked out as "now + what is left of the
--     4 hours, but not after the end of the working day", on clock times.
--     A clock time plus 4 hours wraps at midnight: at 20:06 it gave 00:06,
--     so every written return time was refused. School hours (07:40 to
--     15:30) never reached it; only evening events did.
--     Now the minutes are taken first (what is left of the 4 hours, or the
--     minutes until the end of the working day, whichever is smaller) and
--     only then added to "now". The result can never pass the end of the
--     working day, so it never wraps. One small helper, exit_latest(), does
--     this sum for both work_exit() and exit_rules().
--
--  2. TIME LEFT TODAY, ON THE PHONE THAT CHECKED IN
--     exit_rules() can now be given the phone's device ID. When THAT phone
--     made today's accepted check-in to the event, the answer also carries
--     that one person's time left today, their latest return time, and
--     whether they are out now or have gone home. Nothing else about them:
--     no name, no code, no reason. A typed staff code never unlocks it:
--     the staff page has no login, so a code could be anyone's.
--     Without a matching phone the answer is the same for everyone, as before.
--     work_exit() also says what is left after each Keluar and Masuk semula.
--
--  The 4-hour rule itself does not change: it counts every step-out of
--  the day together (confirmed by the maintainer, 12 Oct 2026). The limit
--  (240 minutes) is still written in three places: work_exit(),
--  exit_rules() and the work_exit_log view.
--
--  PART A : exit_latest()   - the latest return time, without the wrap
--  PART B : work_exit()     - uses it, and says what is left
--  PART C : exit_rules()    - uses it, and the phone's own time left
--  PART D : who may use which door
--
--  What does NOT change
--    * No row of any table is changed.
--    * Every reason word and every existing reply field stays as it was;
--      the new fields are extra, so an older staff page keeps working.
--    * An older staff page that calls exit_rules() with the event code
--      only gets exactly the old answer.
-- =====================================================================

begin;      -- all or nothing: if any part fails, nothing in this file is kept

do $$
begin
  if coalesce(obj_description('public.counter_for(uuid)'::regprocedure, 'pg_proc'), '') not like '%14_counter_active_staff%' then
    raise exception 'STOP: run 14_counter_active_staff.sql first. Nothing was changed.';
  end if;
  if to_regclass('public.push_subscriptions') is not null then
    raise exception 'STOP: 16_push_reminders.sql is already installed. This older file is not needed again. Nothing was changed.';
  end if;
end $$;


-- =====================================================================
-- PART A : exit_latest()
--   The latest return time: "now" plus the smaller of
--     * what is left of today's 4 hours (p_left), and
--     * the minutes until the end of the working day.
--   It can never pass p_end, so it never wraps past midnight.
--   (Before: least(now + left, end) on clock times, which wraps at 24:00.)
--   An inside helper: no page can call it.
-- =====================================================================
create or replace function exit_latest(p_now time, p_end time, p_left integer) returns time
language sql immutable set search_path = public as $$
  select p_now + make_interval(mins => greatest(0, least(coalesce(p_left, 0),
                                                         floor(extract(epoch from (p_end - p_now)) / 60)::integer)));
$$;


-- =====================================================================
-- PART B : work_exit()
--   work_exit() from 13_work_exits.sql, word for word, plus the lines
--   marked "NEW in 15":
--     * the latest return time comes from exit_latest() (the midnight fix);
--     * an accepted Keluar also says minutes_left_if_on_time;
--     * an accepted Masuk semula also says minutes_left.
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
    v_latest := exit_latest(v_minute, v_end, v_left);                 -- NEW in 15: can never pass v_end, so never wraps past midnight

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
                              'name', v_staff.full_name, 'back_by', to_char(v_back, 'HH24:MI'),
                              -- NEW in 15: what is left of today's 4 hours if they are back at the time they wrote
                              'minutes_left_if_on_time', greatest(0, v_left - (extract(epoch from v_back - v_minute) / 60)::integer));
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
                            'over_limit', v_used + v_away > c_limit,
                            'minutes_left', greatest(0, c_limit - (v_used + v_away)));      -- NEW in 15: what is left of today's 4 hours
end;
$$;


-- =====================================================================
-- PART C : exit_rules()
--   The same answer as before for everyone, with the midnight fix, plus
--   (NEW in 15) the time left today for the person whose accepted
--   check-in today, to this event, was made from the phone it is given.
--   A function's inputs cannot be changed in place, so the one-input
--   version is dropped and this one made inside the same all-or-nothing
--   block: there is no moment without it. A call with the event code
--   only still works (the device ID is optional).
-- =====================================================================
drop function if exists exit_rules(text);
create or replace function exit_rules(p_event_code text, p_device_id text default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  c_limit   constant integer := 240;   -- the same 240 as in work_exit() and work_exit_log
  v_event   events%rowtype;
  v_today   date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
  v_minute  time := date_trunc('minute', now() at time zone 'Asia/Kuala_Lumpur')::time;
  v_start   time;
  v_end     time;
  v_open    boolean;
  v_reply   jsonb;
  v_people  integer;
  v_staff   uuid;
  v_used    integer;
  v_left    integer;
  v_exit    work_exits%rowtype;
begin
  if coalesce(length(p_event_code), 0) not between 1 and 60 then
    return jsonb_build_object('ok', false);
  end if;
  -- NEW in 15: the device ID is measured first, with the same rules as check_in().
  --            A bad one is not an error: it is simply ignored, and the general answer is given.
  if coalesce(length(p_device_id), 0) not between 1 and 200 then
    p_device_id := null;
  else
    p_device_id := trim(p_device_id);
    if p_device_id !~ '^[A-Za-z0-9_.:-]{1,64}$' then
      p_device_id := null;
    end if;
  end if;

  select * into v_event from events
   where lower(event_code) = lower(trim(p_event_code)) and active and archived_at is null and allow_exit;
  if v_event.id is null then
    return jsonb_build_object('ok', false);
  end if;
  select d.work_start, d.work_end into v_start, v_end
    from work_day_of(v_event.id, v_today) d;
  if v_start is null or v_end is null then
    return jsonb_build_object('ok', false);
  end if;
  v_open := v_minute >= v_start and v_minute < v_end;

  -- The answer for everyone, as before ("latest" for someone not out yet today). NEW in 15: without the midnight wrap.
  v_reply := jsonb_build_object('ok', true,
                                'limit_minutes', c_limit,
                                'work_start', to_char(v_start, 'HH24:MI'),
                                'work_end',   to_char(v_end,   'HH24:MI'),
                                'now',        to_char(v_minute, 'HH24:MI'),
                                'open_now',   v_open,
                                'latest',     case when v_open then to_char(exit_latest(v_minute, v_end, c_limit), 'HH24:MI') end);
  if p_device_id is null then
    return v_reply;
  end if;

  -- NEW in 15: who made today's accepted check-in to this event from THIS phone?
  --            (The same test work_exit() uses for "checked in today".)
  --            Nobody, or more than one person: the general answer. Never a guess.
  select count(distinct a.staff_id), min(a.staff_id::text)::uuid into v_people, v_staff
    from attendance a
    left join event_windows w on w.id = a.window_id
   where a.event_id = v_event.id and a.attendance_date = v_today and a.status = 'present'
     and a.device_id = p_device_id
     and coalesce(w.counts_as, 'in') = 'in';
  if v_people <> 1 then
    return v_reply;
  end if;

  -- That person's step-outs today, counted exactly as work_exit() counts them.
  select coalesce(sum(greatest(0, extract(epoch from date_trunc('minute', x.back_at) - date_trunc('minute', x.out_at)) / 60)), 0)::integer
    into v_used
    from work_exits x
   where x.staff_id = v_staff and x.exit_date = v_today and x.back_at is not null;
  v_left := greatest(0, c_limit - v_used);

  select * into v_exit from work_exits x
   where x.staff_id = v_staff and x.exit_date = v_today and x.back_at is null
   limit 1;

  -- Only numbers and times about this one person: no name, no code, no reason.
  return v_reply
      || jsonb_build_object('personal', true,
                            'minutes_left', v_left,
                            'latest', case when v_open then to_char(exit_latest(v_minute, v_end, v_left), 'HH24:MI') end)
      || case when v_exit.id is not null and v_exit.going_home then jsonb_build_object('gone_home', true)
              when v_exit.id is not null then jsonb_build_object('out_now', true, 'back_by', to_char(v_exit.planned_back, 'HH24:MI'))
              else '{}'::jsonb end;
end;
$$;


-- =====================================================================
-- PART D : WHO MAY USE WHICH DOOR
-- =====================================================================
revoke all on function exit_latest(time, time, integer) from public, anon, authenticated;     -- inside helper: nobody calls it directly
revoke all on function exit_rules(text, text) from public, anon, authenticated;
grant execute on function exit_rules(text, text) to anon, authenticated;                       -- staff phones: the general answer, or this phone's own time left
revoke all on function work_exit(text, text, text, double precision, double precision, real, text, text, text, boolean) from public, anon, authenticated;
grant execute on function work_exit(text, text, text, double precision, double precision, real, text, text, text, boolean) to anon, authenticated;

commit;


-- ---------------------------------------------------------------------
-- Quick check. You should see one row, every column true:
--   midnight_fixed      = 20:06 with 4 hours left and the day ending at 21:00 gives 21:00 (it used to give 00:06)
--   limit_counts        = 10:00 with 225 minutes left gives 13:45
--   exit_rules_replaced = the old one-input exit_rules() is gone, the new one is there
--   doors_right         = staff phones may call exit_rules(), nobody may call the helper
-- ---------------------------------------------------------------------
select exit_latest('20:06', '21:00', 240) = time '21:00'                                              as midnight_fixed,
       exit_latest('10:00', '15:30', 225) = time '13:45'                                              as limit_counts,
       to_regprocedure('public.exit_rules(text)') is null
         and to_regprocedure('public.exit_rules(text,text)') is not null                              as exit_rules_replaced,
       has_function_privilege('anon', 'public.exit_rules(text,text)', 'execute')
         and not has_function_privilege('anon', 'public.exit_latest(time,time,integer)', 'execute')   as doors_right;
