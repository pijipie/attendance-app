-- =====================================================================
--  ATTENDANCE SYSTEM  -  06_security_hardening.sql
--  Fixes from the security review of 3 Oct 2026.
--
--  Paste this WHOLE file into Supabase > SQL Editor and press RUN (once).
--  Safe to run again.
--
--  PART A : check_in() - limits on what a phone may send, a brake on
--           repeated refusals, and replies that give less away
--  PART B : QR tokens - screens share a token instead of each making one
--  PART C : admins - confirmed accounts only, and never zero owners
--  PART D : screen pairing - cannot be jammed, cannot be approved twice
--  PART E : attendance hours cannot be moved to another event
--  PART F : table rights cut down to what the admin page really uses
--  PART G : indexes, so lists stay fast as the log grows
--  PART H : who may use which door
--
--  What does NOT change
--    * Staff phones still cannot read or write any table.
--    * Nobody can change or delete an attendance row from the website.
--    * No existing "reason" word is renamed, so an older copy of a page
--      keeps working.
-- =====================================================================

-- ---------------------------------------------------------------------
-- GUARD (added 5 Oct 2026). This file is OLDER than 07_window_counter.sql.
-- Running it again after that file would put back the older check_in()
-- and display_poll(). So it checks first, and stops without changing
-- anything.
-- ---------------------------------------------------------------------
begin;      -- all or nothing: if any part fails, nothing in this file is kept
do $$
begin
  if to_regprocedure('public.counter_for(uuid)') is not null then
    raise exception 'STOP: 07_window_counter.sql is already installed. Running this older file again would undo it. Nothing was changed.';
  end if;
end $$;


-- =====================================================================
-- PART A : check_in() version 3
--   Same checks, same order: QR -> time window -> GPS accuracy -> distance
--   -> duplicate. What is new:
--
--   A1. LIMITS. Staff code and event code: 1 to 20 characters. Device ID:
--       1 to 64 letters, digits, - _ . :   QR token: at most 64 characters.
--       GPS accuracy must be a real number, 0 or more. Anything else gets
--       'bad_input' and nothing is stored. (Before, a 1 MB "device ID"
--       was stored as it came.)
--
--   A2. A BRAKE. Every refusal used to store a row, so one known staff
--       code was enough to fill the database or bury a person in
--       "rejected" rows. Now at most 10 refusals per person are stored in
--       any 10 minutes. Further ones get the same answer but no row.
--
--   A3. LESS GIVEN AWAY.
--       * An unknown staff code now walks through the same checks and gets
--         the same answer a real one would. An outsider can no longer use
--         the reply to find out which staff codes exist. Nothing is stored
--         for an unknown code.
--       * The distance to the venue is sent back only with 'outside the
--         area' (where the person needs it) and with an accepted check-in.
--   The same time-window test is used by list_events(). Keep the two the same.
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

-- A second lock on the table itself, in case a future function forgets the
-- limits. "not valid" means: applies to every NEW row, and leaves the rows
-- already in the log alone (the log is never edited).
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'attendance_device_id_short') then
    alter table attendance add constraint attendance_device_id_short
      check (length(device_id) <= 64) not valid;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'attendance_accuracy_real') then
    alter table attendance add constraint attendance_accuracy_real
      check (gps_accuracy_m >= 0 and gps_accuracy_m < 'infinity'::real) not valid;
  end if;
end $$;


-- =====================================================================
-- PART B : QR TOKENS
--   Before: every request for a token made a new one, and used-up tokens
--   stayed in the table for 10 more minutes.
--   Now: a token made in the last few seconds is handed out again, so
--   several screens showing the same event share one, and used-up tokens
--   are removed straight away.
--   How long a scanned token is accepted is still the "QR code lifetime"
--   setting. It has to cover scanning, finding GPS and pressing Submit.
-- =====================================================================
alter table qr_tokens add column if not exists issued_at timestamptz not null default now();

-- An inside helper. Nobody can call it through the website (see PART H);
-- only the two functions below use it.
create or replace function qr_token_for(p_event_id uuid) returns jsonb
language plpgsql set search_path = public as $$
declare
  v_ttl    integer;
  v_token  text;
  v_expiry timestamptz;
begin
  select qr_valid_seconds into v_ttl from org_settings where id = 1;
  delete from qr_tokens t where t.expires_at < now();

  select t.token, t.expires_at into v_token, v_expiry
    from qr_tokens t
   where t.event_id = p_event_id
     and t.expires_at > now()
     and t.issued_at > now() - make_interval(secs => least(10, v_ttl / 4.0))
   order by t.issued_at desc
   limit 1;

  if v_token is null then
    v_token  := substr(replace(gen_random_uuid()::text, '-', ''), 1, 12);
    v_expiry := now() + make_interval(secs => v_ttl);
    insert into qr_tokens (token, event_id, expires_at) values (v_token, p_event_id, v_expiry);
  end if;

  return jsonb_build_object(
    'token', v_token,
    'expires_at', v_expiry,
    'valid_seconds', greatest(1, floor(extract(epoch from v_expiry - now()))::integer));
end;
$$;

create or replace function issue_qr_token(p_event_code text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_event events%rowtype;
begin
  if not is_admin() then
    raise exception 'not_admin' using errcode = '42501';
  end if;
  if coalesce(length(p_event_code), 0) not between 1 and 60 then
    raise exception 'unknown_event';
  end if;

  select * into v_event from events
   where lower(event_code) = lower(trim(p_event_code)) and active and archived_at is null;
  if v_event.id is null then
    raise exception 'unknown_event';
  end if;

  return qr_token_for(v_event.id);      -- token, expires_at, and NEW: valid_seconds
end;
$$;


-- =====================================================================
-- PART C : ADMINS
--   C1. Only an account whose email is CONFIRMED can be made an admin.
--       Otherwise someone could sign up with an address they do not own
--       and wait for the owner to add that address.
--       (Also switch public sign-up off: Supabase > Authentication >
--        Sign In / Providers > "Allow new users to sign up".)
--   C2. Two owners demoting each other in the same instant could leave no
--       owner. The functions now take turns (a lock), and the table itself
--       refuses to end up with admins but no owner.
-- =====================================================================
create or replace function admin_set(p_email text, p_role text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_id        uuid;
  v_confirmed timestamptz;
begin
  if not is_owner() then
    return jsonb_build_object('ok', false, 'reason', 'not_owner');
  end if;
  if p_role is null or p_role not in ('owner', 'manager', 'operator') then
    return jsonb_build_object('ok', false, 'reason', 'bad_role');
  end if;
  if coalesce(length(p_email), 0) not between 3 and 254 then
    return jsonb_build_object('ok', false, 'reason', 'no_such_user');
  end if;

  -- one change to the admins list at a time, then look again at who we are
  lock table admins in share row exclusive mode;
  if not is_owner() then
    return jsonb_build_object('ok', false, 'reason', 'not_owner');
  end if;

  select id, email_confirmed_at into v_id, v_confirmed
    from auth.users where lower(email) = lower(trim(p_email));
  if v_id is null then
    return jsonb_build_object('ok', false, 'reason', 'no_such_user');
  end if;
  if v_confirmed is null then
    return jsonb_build_object('ok', false, 'reason', 'unconfirmed');
  end if;

  -- never leave the system with no owner
  if p_role <> 'owner'
     and exists (select 1 from admins where user_id = v_id and role = 'owner')
     and (select count(*) from admins where role = 'owner') = 1 then
    return jsonb_build_object('ok', false, 'reason', 'last_owner');
  end if;

  insert into admins (user_id, role) values (v_id, p_role)
  on conflict (user_id) do update set role = excluded.role;
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function admin_remove(p_user_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not is_owner() then
    return jsonb_build_object('ok', false, 'reason', 'not_owner');
  end if;

  lock table admins in share row exclusive mode;
  if not is_owner() then
    return jsonb_build_object('ok', false, 'reason', 'not_owner');
  end if;

  if exists (select 1 from admins where user_id = p_user_id and role = 'owner')
     and (select count(*) from admins where role = 'owner') = 1 then
    return jsonb_build_object('ok', false, 'reason', 'last_owner');
  end if;
  delete from admins where user_id = p_user_id;
  return jsonb_build_object('ok', true);
end;
$$;

-- The table's own rule, whatever route the change comes by (the website,
-- the SQL Editor, or deleting the account in Authentication > Users):
-- while there is any admin at all, one of them must be an owner.
create or replace function admins_keep_owner() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from admins)
     and not exists (select 1 from admins where role = 'owner') then
    raise exception 'last_owner: there must be at least one owner' using errcode = '23514';
  end if;
  return null;
end;
$$;

drop trigger if exists admins_keep_owner on admins;
create trigger admins_keep_owner after update or delete on admins
  for each statement execute function admins_keep_owner();


-- =====================================================================
-- PART D : SCREEN PAIRING
--   D1. A pairing code now waits 5 minutes for an admin (was 15), and up
--       to 200 screens may wait (was 40). When the list is full, the
--       OLDEST waiting code makes room, instead of new screens being
--       turned away. So somebody asking for codes in a loop can no longer
--       lock real screens out for 15 minutes at a time.
--   D2. Approving is one single step, so two admins typing the same code
--       cannot both win.
--   D3. Stopping a screen that was never approved now removes its code.
--   The 5 minutes appear in THREE functions below. Change all three together.
-- =====================================================================

-- a waiting code must be the only waiting code with those letters
create unique index if not exists qr_displays_waiting_code
  on qr_displays (pair_code) where event_id is null;

create or replace function display_register(p_secret_hash text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_code  text;
  v_chars constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';   -- no 0/O, 1/I/L
begin
  if p_secret_hash is null or p_secret_hash !~ '^[0-9a-f]{64}$' then
    return jsonb_build_object('ok', false, 'reason', 'bad_input');
  end if;

  -- tidy up: unanswered codes after 5 minutes, finished screens after a day
  delete from qr_displays
   where (event_id is null and created_at < now() - interval '5 minutes')
      or (event_id is not null and coalesce(stopped_at, expires_at) < now() - interval '1 day');

  select pair_code into v_code from qr_displays where secret_hash = p_secret_hash and event_id is null;
  if v_code is not null then
    return jsonb_build_object('ok', true, 'code', v_code);
  end if;
  if exists (select 1 from qr_displays where secret_hash = p_secret_hash) then
    return jsonb_build_object('ok', false, 'reason', 'already_used');
  end if;

  -- keep at most 200 waiting: the oldest ones give up their place
  delete from qr_displays
   where id in (select id from qr_displays where event_id is null
                 order by created_at desc offset 199);

  for attempt in 1 .. 6 loop
    select string_agg(substr(v_chars, 1 + floor(random() * length(v_chars))::int, 1), '')
      into v_code from generate_series(1, 6);
    insert into qr_displays (secret_hash, pair_code) values (p_secret_hash, v_code)
    on conflict do nothing;                     -- same letters already waiting, or this screen asked twice at once
    if found then
      return jsonb_build_object('ok', true, 'code', v_code);
    end if;
    select pair_code into v_code from qr_displays where secret_hash = p_secret_hash and event_id is null;
    if v_code is not null then
      return jsonb_build_object('ok', true, 'code', v_code);
    end if;
  end loop;
  return jsonb_build_object('ok', false, 'reason', 'busy');
end;
$$;

create or replace function display_approve(p_pair_code text, p_event_code text, p_minutes integer) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_event   events%rowtype;
  v_id      uuid;
  v_minutes integer := least(greatest(coalesce(p_minutes, 60), 5), 720);   -- 5 minutes to 12 hours
begin
  if not is_admin() then
    return jsonb_build_object('ok', false, 'reason', 'not_admin');
  end if;
  if coalesce(length(p_event_code), 0) not between 1 and 60 then
    return jsonb_build_object('ok', false, 'reason', 'unknown_event');
  end if;
  if coalesce(length(p_pair_code), 0) not between 1 and 40 then
    return jsonb_build_object('ok', false, 'reason', 'code_not_found');
  end if;

  select * into v_event from events
   where lower(event_code) = lower(trim(p_event_code)) and active and archived_at is null;
  if v_event.id is null then
    return jsonb_build_object('ok', false, 'reason', 'unknown_event');
  end if;

  -- One step: only a code that is still waiting can be taken, and only once.
  update qr_displays
     set event_id = v_event.id, approved_by = auth.uid(), approved_at = now(),
         expires_at = now() + make_interval(mins => v_minutes)
   where pair_code = upper(replace(trim(p_pair_code), ' ', ''))
     and event_id is null
     and stopped_at is null
     and created_at > now() - interval '5 minutes'
  returning id into v_id;
  if v_id is null then
    return jsonb_build_object('ok', false, 'reason', 'code_not_found');
  end if;

  return jsonb_build_object('ok', true, 'event', v_event.name,
                            'expires_at', now() + make_interval(mins => v_minutes));
end;
$$;

create or replace function display_poll(p_secret text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_display qr_displays%rowtype;
  v_event   events%rowtype;
  v_qr      jsonb;
  v_local   timestamp := now() at time zone 'Asia/Kuala_Lumpur';
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
    'ends_at', v_display.expires_at,
    'present', (select count(distinct a.staff_id) from attendance a
                 where a.event_id = v_event.id and a.status = 'present'
                   and a.attendance_date = v_local::date),
    'total', (select count(*) from staff where active));
end;
$$;

create or replace function display_stop(p_display_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then
    return jsonb_build_object('ok', false, 'reason', 'not_admin');
  end if;

  -- never approved: the code is simply withdrawn
  delete from qr_displays where id = p_display_id and event_id is null;
  if found then
    return jsonb_build_object('ok', true);
  end if;

  update qr_displays set stopped_at = now() where id = p_display_id and stopped_at is null;
  if not found and not exists (select 1 from qr_displays where id = p_display_id) then
    return jsonb_build_object('ok', false, 'reason', 'not_found');
  end if;
  return jsonb_build_object('ok', true);
end;
$$;


-- =====================================================================
-- PART E : ATTENDANCE HOURS STAY WITH THEIR EVENT
--   Attendance rows point at a session (hours). If a session could be
--   moved to another event, yesterday's attendance would silently read as
--   attendance for that other event. Name, days and times can still be
--   edited; the event it belongs to cannot.
-- =====================================================================
create or replace function event_windows_keep_event() returns trigger
language plpgsql set search_path = public as $$
begin
  if new.event_id is distinct from old.event_id then
    raise exception 'attendance hours cannot be moved to another event' using errcode = '23514';
  end if;
  return new;
end;
$$;

drop trigger if exists event_windows_keep_event on event_windows;
create trigger event_windows_keep_event before update on event_windows
  for each row execute function event_windows_keep_event();


-- =====================================================================
-- PART F : TABLE RIGHTS
--   Supabase gives every signed-in account ALL rights on every table
--   (including TRUNCATE = "empty the table") and relies on the row rules
--   alone to stop them. Here the rights are cut down to what the admin
--   page really uses, so there are two locks instead of one.
--   Functions marked "security definer" keep working: they run with the
--   owner's rights, not the caller's.
-- =====================================================================
revoke all on all tables in schema public from anon;
revoke all on all tables in schema public from authenticated;

grant select, insert, update, delete on staff, events, event_windows to authenticated;
grant select, update                 on org_settings                 to authenticated;
grant select                         on attendance, attendance_log   to authenticated;   -- the log is read-only
grant select                         on qr_displays, admin_audit     to authenticated;
-- admins and qr_tokens: no rights at all. They are reached only through functions.


-- =====================================================================
-- PART G : INDEXES
--   The attendance screen asks "all rows of this date"; the QR screens ask
--   "who is present at this event today". Without these the database
--   reads the whole log every time, which gets slower every month.
-- =====================================================================
create index if not exists attendance_date_idx       on attendance (attendance_date, checked_in_at, id);
create index if not exists attendance_event_date_idx on attendance (event_id, attendance_date, status);


-- =====================================================================
-- PART H : WHO MAY USE WHICH DOOR
--   Close every door touched in this file, then open each one on purpose.
-- =====================================================================
revoke all on function qr_token_for(uuid)                    from public, anon, authenticated;   -- inside helper: nobody
revoke all on function admins_keep_owner()                   from public, anon, authenticated;
revoke all on function event_windows_keep_event()            from public, anon, authenticated;
revoke all on function check_in(text, text, double precision, double precision, real, text, text) from public, anon, authenticated;
revoke all on function issue_qr_token(text)                  from public, anon, authenticated;
revoke all on function admin_set(text, text)                 from public, anon, authenticated;
revoke all on function admin_remove(uuid)                    from public, anon, authenticated;
revoke all on function display_register(text)                from public, anon, authenticated;
revoke all on function display_approve(text, text, integer)  from public, anon, authenticated;
revoke all on function display_poll(text)                    from public, anon, authenticated;
revoke all on function display_stop(uuid)                    from public, anon, authenticated;

-- staff phones and the big screen (no login)
grant execute on function check_in(text, text, double precision, double precision, real, text, text) to anon, authenticated;
grant execute on function display_register(text) to anon, authenticated;
grant execute on function display_poll(text)     to anon, authenticated;

-- signed-in people. Each function checks the level itself.
grant execute on function issue_qr_token(text)                 to authenticated;
grant execute on function admin_set(text, text)                to authenticated;
grant execute on function admin_remove(uuid)                   to authenticated;
grant execute on function display_approve(text, text, integer) to authenticated;
grant execute on function display_stop(uuid)                   to authenticated;

commit;


-- ---------------------------------------------------------------------
-- Quick check. You should see ONE row:
--   new_functions  = 3
--   new_triggers   = 2
--   new_indexes    = 3
--   signed_in_can_empty_tables = false
--   anon_table_rights = 0
--   owners         = 1 or more
-- ---------------------------------------------------------------------
select
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('qr_token_for', 'admins_keep_owner', 'event_windows_keep_event'))            as new_functions,
  (select count(*) from pg_trigger
    where tgname in ('admins_keep_owner', 'event_windows_keep_event') and not tgisinternal)          as new_triggers,
  (select count(*) from pg_indexes
    where schemaname = 'public'
      and indexname in ('attendance_date_idx', 'attendance_event_date_idx', 'qr_displays_waiting_code')) as new_indexes,
  exists (select 1 from information_schema.role_table_grants
           where table_schema = 'public' and grantee = 'authenticated' and privilege_type = 'TRUNCATE') as signed_in_can_empty_tables,
  (select count(*) from information_schema.role_table_grants
    where table_schema = 'public' and grantee = 'anon')                                              as anon_table_rights,
  (select count(*) from admins where role = 'owner')                                                 as owners;
