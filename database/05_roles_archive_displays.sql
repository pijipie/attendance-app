-- =====================================================================
--  ATTENDANCE SYSTEM  -  05_roles_archive_displays.sql
--
--  Paste this WHOLE file into Supabase > SQL Editor and press RUN (once).
--  Safe to run again.
--
--  PART A : three admin levels (owner, manager, operator)
--  PART B : archive instead of delete, so the attendance log is never lost
--  PART C : an activity record of who changed what
--  PART D : "screen pairing" - show the QR on a big screen with no login
--  PART E : who may use which door
--
--  What does NOT change
--    * Staff phones still cannot read or write any table.
--    * Nobody can change or delete an attendance row from the website.
-- =====================================================================


-- =====================================================================
-- PART A : ADMIN LEVELS
--   owner    : everything, including settings and managing other admins
--   manager  : QR, attendance, and editing events, hours and staff
--   operator : shows the QR and views attendance. Cannot change anything.
-- =====================================================================

alter table admins add column if not exists role text not null default 'operator';

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'admins_role_check') then
    alter table admins add constraint admins_role_check
      check (role in ('owner', 'manager', 'operator'));
  end if;
end $$;

-- The first time this runs, nobody is an owner yet, so everyone who is
-- already an admin (today: only you) becomes an owner.
update admins set role = 'owner'
 where not exists (select 1 from admins where role = 'owner');

-- Three small questions the rest of the file keeps asking.
create or replace function admin_role() returns text
language sql stable security definer set search_path = public as $$
  select role from admins where user_id = auth.uid();
$$;

create or replace function can_manage() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select role from admins where user_id = auth.uid()) in ('owner', 'manager'), false);
$$;

create or replace function is_owner() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select role from admins where user_id = auth.uid()) = 'owner', false);
$$;

-- Reading stays open to every admin level (is_admin(), from 01_schema.sql).
-- Writing now needs manager or owner. Settings need owner.
drop policy if exists admin_insert on staff;
drop policy if exists admin_update on staff;
drop policy if exists admin_delete on staff;
create policy admin_insert on staff for insert to authenticated with check (can_manage());
create policy admin_update on staff for update to authenticated using (can_manage()) with check (can_manage());
create policy admin_delete on staff for delete to authenticated using (can_manage());

drop policy if exists admin_insert on events;
drop policy if exists admin_update on events;
drop policy if exists admin_delete on events;
create policy admin_insert on events for insert to authenticated with check (can_manage());
create policy admin_update on events for update to authenticated using (can_manage()) with check (can_manage());
create policy admin_delete on events for delete to authenticated using (can_manage());

drop policy if exists admin_insert on event_windows;
drop policy if exists admin_update on event_windows;
drop policy if exists admin_delete on event_windows;
create policy admin_insert on event_windows for insert to authenticated with check (can_manage());
create policy admin_update on event_windows for update to authenticated using (can_manage()) with check (can_manage());
create policy admin_delete on event_windows for delete to authenticated using (can_manage());

drop policy if exists admin_update on org_settings;
create policy admin_update on org_settings for update to authenticated using (is_owner()) with check (is_owner());

-- ---------------------------------------------------------------------
-- Managing admins (owner only).
--   An admin is a Supabase user who is ALSO listed in the "admins" table.
--   Step 1 (in Supabase): Authentication > Users > Add user.
--   Step 2 (in the admin page): Settings > Admins > type that email, pick a level.
--   These three functions are what step 2 uses.
-- ---------------------------------------------------------------------
create or replace function admin_list()
returns table (user_id uuid, email text, role text, created_at timestamptz, is_me boolean)
language sql stable security definer set search_path = public as $$
  select a.user_id, u.email::text, a.role, a.created_at, a.user_id = auth.uid()
    from admins a
    join auth.users u on u.id = a.user_id
   where is_owner()
   order by case a.role when 'owner' then 1 when 'manager' then 2 else 3 end, u.email;
$$;

create or replace function admin_set(p_email text, p_role text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
begin
  if not is_owner() then
    return jsonb_build_object('ok', false, 'reason', 'not_owner');
  end if;
  if p_role is null or p_role not in ('owner', 'manager', 'operator') then
    return jsonb_build_object('ok', false, 'reason', 'bad_role');
  end if;

  select id into v_id from auth.users where lower(email) = lower(trim(p_email));
  if v_id is null then
    return jsonb_build_object('ok', false, 'reason', 'no_such_user');
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
  if exists (select 1 from admins where user_id = p_user_id and role = 'owner')
     and (select count(*) from admins where role = 'owner') = 1 then
    return jsonb_build_object('ok', false, 'reason', 'last_owner');
  end if;
  delete from admins where user_id = p_user_id;
  return jsonb_build_object('ok', true);
end;
$$;


-- =====================================================================
-- PART B : ARCHIVE INSTEAD OF DELETE
--   The problem: an event that has attendance cannot be deleted, because
--   the attendance rows point at it. Deleting those rows would destroy
--   the record.
--   The answer: an "archived" stamp. An archived event or session
--     * disappears from the staff page, the QR screen and the normal lists
--     * can no longer be checked in to
--     * still gives its name to the old attendance rows
--   So the lists stay short after years of use and the log stays whole.
-- =====================================================================

alter table events        add column if not exists archived_at timestamptz;
alter table event_windows add column if not exists archived_at timestamptz;

-- An event code must be unique only among events that are NOT archived.
-- That lets you reuse a code (for example SUKAN) next year.
drop index if exists events_code_unique;
create unique index events_code_unique on events (lower(event_code)) where archived_at is null;

-- Remove an event. If it has attendance it is archived, otherwise it is
-- really deleted. Returns 'deleted', 'archived' or 'not_found'.
create or replace function remove_event(p_event_id uuid) returns text
language plpgsql set search_path = public as $$
begin
  if not can_manage() then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  if not exists (select 1 from events where id = p_event_id) then
    return 'not_found';
  end if;
  if exists (select 1 from attendance where event_id = p_event_id) then
    update events set archived_at = coalesce(archived_at, now()), active = false where id = p_event_id;
    return 'archived';
  end if;
  delete from events where id = p_event_id;      -- its hours go with it
  return 'deleted';
end;
$$;

-- The same for one session (attendance hours) of an event.
create or replace function remove_window(p_window_id uuid) returns text
language plpgsql set search_path = public as $$
begin
  if not can_manage() then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  if not exists (select 1 from event_windows where id = p_window_id) then
    return 'not_found';
  end if;
  if exists (select 1 from attendance where window_id = p_window_id) then
    update event_windows set archived_at = coalesce(archived_at, now()) where id = p_window_id;
    return 'archived';
  end if;
  delete from event_windows where id = p_window_id;
  return 'deleted';
end;
$$;

-- ---------------------------------------------------------------------
-- The three doors now skip archived events and archived sessions.
-- Everything else in them is unchanged.
-- ---------------------------------------------------------------------
create or replace function list_events()
returns table (event_code text, name text, require_qr boolean, open_now boolean)
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
         ) as open_now
    from events e
   cross join (select now() at time zone 'Asia/Kuala_Lumpur' as local_now) t
   where e.active and e.archived_at is null
   order by e.name;
$$;

create or replace function issue_qr_token(p_event_code text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_event  events%rowtype;
  v_ttl    integer;
  v_token  text := substr(replace(gen_random_uuid()::text, '-', ''), 1, 12);
  v_expiry timestamptz;
begin
  if not is_admin() then
    raise exception 'not_admin' using errcode = '42501';
  end if;

  select * into v_event from events
   where lower(event_code) = lower(trim(p_event_code)) and active and archived_at is null;
  if v_event.id is null then
    raise exception 'unknown_event';
  end if;

  select qr_valid_seconds into v_ttl from org_settings where id = 1;
  v_expiry := now() + make_interval(secs => v_ttl);

  delete from qr_tokens where expires_at < now() - interval '10 minutes';
  insert into qr_tokens (token, event_id, expires_at)
  values (v_token, v_event.id, v_expiry);

  return jsonb_build_object('token', v_token, 'expires_at', v_expiry);
end;
$$;

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
  v_device    text := trim(p_device_id);
begin
  -- 0. basic sanity of what the phone sent
  if p_lat is null or p_lng is null or p_accuracy is null
     or p_lat not between -90 and 90 or p_lng not between -180 and 180
     or coalesce(length(v_device), 0) = 0 then
    return jsonb_build_object('ok', false, 'reason', 'bad_input');
  end if;

  -- 1. who and where (case-insensitive codes; archived events do not count)
  select * into v_staff from staff
   where lower(staff_code) = lower(trim(p_staff_code)) and active;
  select * into v_event from events
   where lower(event_code) = lower(trim(p_event_code)) and active and archived_at is null;

  if v_staff.id is null or v_event.id is null then
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
              and t.expires_at > now())            then 'qr_invalid_or_expired'
    when v_window_id is null                       then 'outside_time_window'
    when p_accuracy > v_settings.max_gps_accuracy_m then 'gps_accuracy_too_low'
    when v_distance > v_event.radius_m             then 'outside_geofence'
  end;

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
                     and a.device_id = v_device) then
      v_reason := 'device_already_used';
    end if;
  end if;

  -- 5. write the log row (accepted OR rejected, both are kept as evidence)
  begin
    insert into attendance
          (staff_id, event_id, window_id, latitude, longitude, gps_accuracy_m,
           distance_m, radius_applied_m, device_id, status, reason)
    values (v_staff.id, v_event.id, v_window_id, p_lat, p_lng, p_accuracy,
            v_distance, v_event.radius_m, v_device,
            case when v_reason is null then 'present'::attendance_status
                 else 'rejected'::attendance_status end,
            v_reason);
  exception
    when unique_violation then
      v_reason := 'duplicate_same_moment';
      insert into attendance
            (staff_id, event_id, window_id, latitude, longitude, gps_accuracy_m,
             distance_m, radius_applied_m, device_id, status, reason)
      values (v_staff.id, v_event.id, v_window_id, p_lat, p_lng, p_accuracy,
              v_distance, v_event.radius_m, v_device, 'rejected', v_reason);
  end;

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

  return jsonb_build_object('ok', false, 'reason', v_reason,
                            'distance_m', round(v_distance::numeric, 1));
end;
$$;


-- =====================================================================
-- PART C : ACTIVITY RECORD
--   With several admins you need to know who changed what. From now on
--   every add, change and removal of staff, events, hours, settings and
--   admins writes one line here automatically. Only an owner can read it.
--   Nobody can edit it from the website.
--   A change made here in the SQL Editor shows with no name.
-- =====================================================================
create table if not exists admin_audit (
  id           bigint generated always as identity primary key,
  at           timestamptz not null default now(),
  actor        uuid,
  actor_email  text,
  action       text not null,       -- insert / update / delete
  target       text not null,       -- which table
  summary      text,                -- the code or name of the row
  detail       jsonb                -- for a change: {"field": [before, after]}
);
create index if not exists admin_audit_at_idx on admin_audit (at desc);

alter table admin_audit enable row level security;
drop policy if exists owner_read on admin_audit;
create policy owner_read on admin_audit for select to authenticated using (is_owner());
revoke all on admin_audit from anon;

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

  insert into admin_audit (actor, actor_email, action, target, summary, detail)
  values (auth.uid(), (select email from auth.users where id = auth.uid()),
          lower(tg_op), tg_table_name, v_label, v_detail);
  return null;
end;
$$;

drop trigger if exists audit_staff         on staff;
drop trigger if exists audit_events        on events;
drop trigger if exists audit_event_windows on event_windows;
drop trigger if exists audit_org_settings  on org_settings;
drop trigger if exists audit_admins        on admins;
create trigger audit_staff         after insert or update or delete on staff         for each row execute function audit_row();
create trigger audit_events        after insert or update or delete on events        for each row execute function audit_row();
create trigger audit_event_windows after insert or update or delete on event_windows for each row execute function audit_row();
create trigger audit_org_settings  after insert or update or delete on org_settings  for each row execute function audit_row();
create trigger audit_admins        after insert or update or delete on admins        for each row execute function audit_row();


-- =====================================================================
-- PART D : SCREEN PAIRING
--   Goal: show the rotating QR on a big screen WITHOUT typing a password
--   on that screen.
--   1. The screen opens display.html. It invents a long secret, keeps it,
--      and sends only a fingerprint (hash) of it here. It gets back a
--      short code to show, for example "K7P3QX".
--   2. An admin, signed in on their own phone, types that code and
--      chooses the event and for how long.
--   3. The screen keeps asking "anything for me?" with its secret and,
--      once approved, receives a fresh QR token each time.
--   The short code is useless by itself: only a signed-in admin can
--   approve it, and only the screen holding the secret can collect.
-- =====================================================================
create table if not exists qr_displays (
  id           uuid primary key default gen_random_uuid(),
  secret_hash  text not null unique,
  pair_code    text not null,
  created_at   timestamptz not null default now(),
  event_id     uuid references events(id) on delete cascade,   -- empty until approved
  approved_by  uuid,
  approved_at  timestamptz,
  expires_at   timestamptz,
  stopped_at   timestamptz,
  last_seen_at timestamptz
);
alter table qr_displays enable row level security;
drop policy if exists admin_read on qr_displays;
create policy admin_read on qr_displays for select to authenticated using (is_admin());
revoke all on qr_displays from anon;

-- Step 1: the screen announces itself.
create or replace function display_register(p_secret_hash text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_code  text;
  v_chars constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';   -- no 0/O, 1/I/L
begin
  if p_secret_hash is null or p_secret_hash !~ '^[0-9a-f]{64}$' then
    return jsonb_build_object('ok', false, 'reason', 'bad_input');
  end if;

  -- tidy up: unanswered codes after 15 minutes, finished screens after a day
  delete from qr_displays
   where (event_id is null and created_at < now() - interval '15 minutes')
      or (event_id is not null and coalesce(stopped_at, expires_at) < now() - interval '1 day');

  select pair_code into v_code from qr_displays where secret_hash = p_secret_hash and event_id is null;
  if v_code is not null then
    return jsonb_build_object('ok', true, 'code', v_code);
  end if;
  if exists (select 1 from qr_displays where secret_hash = p_secret_hash) then
    return jsonb_build_object('ok', false, 'reason', 'already_used');
  end if;

  -- a limit, so nobody can fill the table by asking for codes in a loop
  if (select count(*) from qr_displays where event_id is null) >= 40 then
    return jsonb_build_object('ok', false, 'reason', 'busy');
  end if;

  loop
    select string_agg(substr(v_chars, 1 + floor(random() * length(v_chars))::int, 1), '')
      into v_code from generate_series(1, 6);
    exit when not exists (select 1 from qr_displays where pair_code = v_code and event_id is null);
  end loop;

  insert into qr_displays (secret_hash, pair_code) values (p_secret_hash, v_code);
  return jsonb_build_object('ok', true, 'code', v_code);
end;
$$;

-- Step 2: a signed-in admin approves the code.
create or replace function display_approve(p_pair_code text, p_event_code text, p_minutes integer) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_event   events%rowtype;
  v_display qr_displays%rowtype;
  v_minutes integer := least(greatest(coalesce(p_minutes, 60), 5), 720);   -- 5 minutes to 12 hours
begin
  if not is_admin() then
    return jsonb_build_object('ok', false, 'reason', 'not_admin');
  end if;

  select * into v_event from events
   where lower(event_code) = lower(trim(p_event_code)) and active and archived_at is null;
  if v_event.id is null then
    return jsonb_build_object('ok', false, 'reason', 'unknown_event');
  end if;

  select * into v_display from qr_displays
   where pair_code = upper(replace(trim(p_pair_code), ' ', ''))
     and event_id is null
     and created_at > now() - interval '15 minutes';
  if v_display.id is null then
    return jsonb_build_object('ok', false, 'reason', 'code_not_found');
  end if;

  update qr_displays
     set event_id = v_event.id, approved_by = auth.uid(), approved_at = now(),
         expires_at = now() + make_interval(mins => v_minutes)
   where id = v_display.id;

  return jsonb_build_object('ok', true, 'event', v_event.name,
                            'expires_at', now() + make_interval(mins => v_minutes));
end;
$$;

-- Step 3: the screen collects. Called every few seconds by display.html.
create or replace function display_poll(p_secret text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_display qr_displays%rowtype;
  v_event   events%rowtype;
  v_ttl     integer;
  v_token   text := substr(replace(gen_random_uuid()::text, '-', ''), 1, 12);
  v_local   timestamp := now() at time zone 'Asia/Kuala_Lumpur';
begin
  if p_secret is null or length(p_secret) < 32 then
    return jsonb_build_object('state', 'unknown');
  end if;

  select * into v_display from qr_displays
   where secret_hash = encode(sha256(convert_to(p_secret, 'UTF8')), 'hex');
  if v_display.id is null then
    return jsonb_build_object('state', 'unknown');
  end if;
  if v_display.event_id is null then
    if v_display.created_at < now() - interval '15 minutes' then
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

  select qr_valid_seconds into v_ttl from org_settings where id = 1;
  delete from qr_tokens where expires_at < now() - interval '10 minutes';
  insert into qr_tokens (token, event_id, expires_at)
  values (v_token, v_event.id, now() + make_interval(secs => v_ttl));
  update qr_displays set last_seen_at = now() where id = v_display.id;

  return jsonb_build_object(
    'state', 'showing',
    'event_code', v_event.event_code,
    'event_name', v_event.name,
    'token', v_token,
    'valid_seconds', v_ttl,
    'ends_at', v_display.expires_at,
    'present', (select count(distinct a.staff_id) from attendance a
                 where a.event_id = v_event.id and a.status = 'present'
                   and a.attendance_date = v_local::date),
    'total', (select count(*) from staff where active));
end;
$$;

-- An admin switches a screen off.
create or replace function display_stop(p_display_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then
    return jsonb_build_object('ok', false, 'reason', 'not_admin');
  end if;
  update qr_displays set stopped_at = now() where id = p_display_id and stopped_at is null;
  return jsonb_build_object('ok', true);
end;
$$;


-- =====================================================================
-- PART E : WHO MAY USE WHICH DOOR
--   Supabase lets everyone call a new function unless we say otherwise.
--   So: first close every door in this file, then open each one on purpose.
-- =====================================================================
revoke all on function admin_role()                          from public, anon, authenticated;
revoke all on function can_manage()                          from public, anon, authenticated;
revoke all on function is_owner()                            from public, anon, authenticated;
revoke all on function admin_list()                          from public, anon, authenticated;
revoke all on function admin_set(text, text)                 from public, anon, authenticated;
revoke all on function admin_remove(uuid)                    from public, anon, authenticated;
revoke all on function remove_event(uuid)                    from public, anon, authenticated;
revoke all on function remove_window(uuid)                   from public, anon, authenticated;
revoke all on function audit_row()                           from public, anon, authenticated;
revoke all on function display_register(text)                from public, anon, authenticated;
revoke all on function display_approve(text, text, integer)  from public, anon, authenticated;
revoke all on function display_poll(text)                    from public, anon, authenticated;
revoke all on function display_stop(uuid)                    from public, anon, authenticated;
revoke all on function list_events()                         from public, anon, authenticated;
revoke all on function issue_qr_token(text)                  from public, anon, authenticated;
revoke all on function check_in(text, text, double precision, double precision, real, text, text) from public, anon, authenticated;

-- staff phones and the big screen (no login)
grant execute on function list_events()          to anon, authenticated;
grant execute on function check_in(text, text, double precision, double precision, real, text, text) to anon, authenticated;
grant execute on function display_register(text) to anon, authenticated;
grant execute on function display_poll(text)     to anon, authenticated;

-- signed-in people. Each function checks the level itself.
grant execute on function admin_role()                         to authenticated;
grant execute on function can_manage()                         to authenticated;
grant execute on function is_owner()                           to authenticated;
grant execute on function admin_list()                         to authenticated;
grant execute on function admin_set(text, text)                to authenticated;
grant execute on function admin_remove(uuid)                   to authenticated;
grant execute on function remove_event(uuid)                   to authenticated;
grant execute on function remove_window(uuid)                  to authenticated;
grant execute on function issue_qr_token(text)                 to authenticated;
grant execute on function display_approve(text, text, integer) to authenticated;
grant execute on function display_stop(uuid)                   to authenticated;


-- ---------------------------------------------------------------------
-- Quick check. You should see:
--   your own email with the level "owner"
--   archived_events = 0
--   audit_triggers  = 5
-- ---------------------------------------------------------------------
select u.email, a.role,
       (select count(*) from events where archived_at is not null)              as archived_events,
       (select count(*) from pg_trigger where tgname like 'audit\_%' and not tgisinternal) as audit_triggers
from   admins a
join   auth.users u on u.id = a.user_id
order  by a.role;
