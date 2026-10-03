-- =====================================================================
--  ATTENDANCE SYSTEM  -  Geo-fencing + rotating QR  -  DATABASE v1
--  Paste this WHOLE file into Supabase > SQL Editor and press RUN (once).
--  Time zone used for "today" and time windows: Asia/Kuala_Lumpur.
-- =====================================================================

-- ---------------------------------------------------------------------
-- GUARD (added 3 Oct 2026). This file is OLDER than 05_roles_archive_displays.sql.
-- Running it again after that file would put back the older, weaker
-- rules. So it checks first, and stops without changing anything.
-- "begin" ... "commit" make the whole file all-or-nothing.
-- ---------------------------------------------------------------------
begin;
do $$
begin
  if to_regprocedure('public.can_manage()') is not null then
    raise exception 'STOP: 05_roles_archive_displays.sql is already installed. Running this older file again would undo its stricter rules. Nothing was changed.';
  end if;
end $$;


-- ---------------------------------------------------------------------
-- SECTION 1 : A list of allowed words for "status"
-- ---------------------------------------------------------------------
create type attendance_status as enum ('present', 'rejected');


-- ---------------------------------------------------------------------
-- SECTION 2 : Settings (replaces the Config tab). Exactly ONE row.
--             The old AdminPIN is gone on purpose: admins will log in.
-- ---------------------------------------------------------------------
create table org_settings (
  id                  integer primary key default 1 check (id = 1),
  organization_name   text    not null,
  max_gps_accuracy_m  integer not null default 30  check (max_gps_accuracy_m > 0),
  qr_valid_seconds    integer not null default 60  check (qr_valid_seconds between 10 and 600)
);

insert into org_settings (organization_name, max_gps_accuracy_m)
values ('Sek. Ren. Islam Al-Irsyad Balok', 30);


-- ---------------------------------------------------------------------
-- SECTION 3 : People (replaces the Staff tab)
--             staff_type replaces the "blank row" trick in the Sheet.
-- ---------------------------------------------------------------------
create table staff (
  id          uuid    primary key default gen_random_uuid(),
  staff_code  text    not null,
  full_name   text    not null,
  email       text,
  staff_type  text    not null default 'staff'
              check (staff_type in ('staff', 'intern_contract')),
  active      boolean not null default true
);
create unique index staff_code_unique on staff (lower(staff_code));


-- ---------------------------------------------------------------------
-- SECTION 4 : Places / events (replaces the Events tab)
--             require_qr = true  -> staff must scan the rotating QR.
-- ---------------------------------------------------------------------
create table events (
  id          uuid    primary key default gen_random_uuid(),
  event_code  text    not null,
  name        text    not null,
  latitude    double precision not null check (latitude  between  -90 and  90),
  longitude   double precision not null check (longitude between -180 and 180),
  radius_m    integer not null check (radius_m > 0),
  require_qr  boolean not null default true,
  active      boolean not null default true
);
create unique index events_code_unique on events (lower(event_code));


-- ---------------------------------------------------------------------
-- SECTION 5 : Allowed check-in times (NEW). One event can have many.
--   Daily school hours : weekdays {1,2,3,4,5}, 07:00-08:30, no dates
--   One-off event      : starts_on = ends_on = that date, 09:00-17:00
--   Two sessions a day : two rows for the same event
--   weekdays use ISO numbers: 1 = Monday ... 7 = Sunday
-- ---------------------------------------------------------------------
create table event_windows (
  id          uuid     primary key default gen_random_uuid(),
  event_id    uuid     not null references events(id) on delete cascade,
  label       text     not null,
  weekdays    smallint[],
  start_time  time     not null,
  end_time    time     not null,
  starts_on   date,
  ends_on     date,
  check (end_time > start_time),
  check (weekdays is null or weekdays <@ array[1,2,3,4,5,6,7]::smallint[]),
  check (starts_on is null or ends_on is null or ends_on >= starts_on)
);
create index event_windows_event_idx on event_windows (event_id);


-- ---------------------------------------------------------------------
-- SECTION 6 : Admins (NEW). Who may see everything and show the QR.
--             Linked to Supabase's own login system (auth.users).
-- ---------------------------------------------------------------------
create table admins (
  user_id     uuid primary key references auth.users(id) on delete cascade,
  created_at  timestamptz not null default now()
);


-- ---------------------------------------------------------------------
-- SECTION 7 : Rotating QR codes (NEW). Short-lived secret words.
-- ---------------------------------------------------------------------
create table qr_tokens (
  token       text primary key,
  event_id    uuid not null references events(id) on delete cascade,
  expires_at  timestamptz not null
);
create index qr_tokens_event_idx on qr_tokens (event_id, expires_at);


-- ---------------------------------------------------------------------
-- SECTION 8 : The attendance log (replaces the Records tab)
--             No names or event titles copied here: only IDs + facts
--             measured at that moment (position, accuracy, device...).
-- ---------------------------------------------------------------------
create table attendance (
  id                uuid primary key default gen_random_uuid(),
  staff_id          uuid not null references staff(id),
  event_id          uuid not null references events(id),
  window_id         uuid references event_windows(id),
  checked_in_at     timestamptz not null default now(),
  attendance_date   date not null default ((now() at time zone 'Asia/Kuala_Lumpur')::date),
  latitude          double precision not null,
  longitude         double precision not null,
  gps_accuracy_m    real    not null,
  distance_m        real    not null,
  radius_applied_m  integer not null,
  device_id         text    not null check (length(device_id) > 0),
  status            attendance_status not null,
  reason            text,
  check (status <> 'present' or window_id is not null)
);

create index attendance_event_idx on attendance (event_id, checked_in_at);
create index attendance_staff_idx on attendance (staff_id, checked_in_at);

-- RULE A: one person checks in only ONCE per session per day.
create unique index one_checkin_per_person_per_session_day
  on attendance (staff_id, window_id, attendance_date)
  where status = 'present';

-- RULE B: one device serves only ONE person per session per day
--         (this is the anti buddy-punching rule). A person may still use
--         several different devices on different days.
create unique index one_person_per_device_per_session_day
  on attendance (device_id, window_id, attendance_date)
  where status = 'present';


-- ---------------------------------------------------------------------
-- SECTION 9 : A readable view for admins (joins the IDs back to names)
-- ---------------------------------------------------------------------
create view attendance_log with (security_invoker = on) as
select  (a.checked_in_at at time zone 'Asia/Kuala_Lumpur') as local_time,
        s.staff_code,
        s.full_name,
        e.name        as event,
        w.label       as session,
        a.status,
        a.reason,
        a.distance_m,
        a.gps_accuracy_m,
        a.device_id
from    attendance a
join    staff  s on s.id = a.staff_id
join    events e on e.id = a.event_id
left join event_windows w on w.id = a.window_id
order by a.checked_in_at desc;


-- ---------------------------------------------------------------------
-- SECTION 10 : Locks. Nobody can read or write tables directly from the
--              website. Only admins may read; only the functions below
--              (the "doors") may write.
-- ---------------------------------------------------------------------
create or replace function is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from admins where user_id = auth.uid());
$$;

alter table org_settings  enable row level security;
alter table staff         enable row level security;
alter table events        enable row level security;
alter table event_windows enable row level security;
alter table admins        enable row level security;
alter table qr_tokens     enable row level security;
alter table attendance    enable row level security;

create policy admin_read on org_settings  for select to authenticated using (is_admin());
create policy admin_read on staff         for select to authenticated using (is_admin());
create policy admin_read on events        for select to authenticated using (is_admin());
create policy admin_read on event_windows for select to authenticated using (is_admin());
create policy admin_read on attendance    for select to authenticated using (is_admin());

revoke all on all tables in schema public from anon;


-- ---------------------------------------------------------------------
-- SECTION 11 : DOOR 1 - check_in()  (used by every staff phone)
--   The phone only reports facts. THIS function decides.
--   Order of checks: QR -> time window -> GPS accuracy -> distance.
-- ---------------------------------------------------------------------
create or replace function check_in(
  p_staff_code  text,
  p_event_code  text,
  p_lat         double precision,
  p_lng         double precision,
  p_accuracy    real,
  p_device_id   text,
  p_qr_token    text default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_staff     staff%rowtype;
  v_event     events%rowtype;
  v_settings  org_settings%rowtype;
  v_local     timestamp := now() at time zone 'Asia/Kuala_Lumpur';
  v_window_id uuid;
  v_distance  double precision;
  v_reason    text;
begin
  -- 0. basic sanity of what the phone sent
  if p_lat is null or p_lng is null or p_accuracy is null
     or p_lat not between -90 and 90 or p_lng not between -180 and 180
     or coalesce(length(trim(p_device_id)), 0) = 0 then
    return jsonb_build_object('ok', false, 'reason', 'bad_input');
  end if;

  -- 1. who and where (case-insensitive codes)
  select * into v_staff from staff
   where lower(staff_code) = lower(trim(p_staff_code)) and active;
  select * into v_event from events
   where lower(event_code) = lower(trim(p_event_code)) and active;

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
  select w.id into v_window_id
    from event_windows w
   where w.event_id = v_event.id
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

  -- 5. write the log row (accepted OR rejected, both are kept as evidence)
  insert into attendance
        (staff_id, event_id, window_id, latitude, longitude, gps_accuracy_m,
         distance_m, radius_applied_m, device_id, status, reason)
  values (v_staff.id, v_event.id, v_window_id, p_lat, p_lng, p_accuracy,
          v_distance, v_event.radius_m, trim(p_device_id),
          case when v_reason is null then 'present'::attendance_status
               else 'rejected'::attendance_status end,
          v_reason);

  if v_reason is null then
    return jsonb_build_object('ok', true,
                              'name', v_staff.full_name,
                              'event', v_event.name,
                              'distance_m', round(v_distance::numeric, 1));
  end if;

  return jsonb_build_object('ok', false, 'reason', v_reason,
                            'distance_m', round(v_distance::numeric, 1));

exception
  when unique_violation then   -- Rule A or Rule B was broken
    return jsonb_build_object('ok', false,
                              'reason', 'duplicate_or_device_already_used');
end;
$$;


-- ---------------------------------------------------------------------
-- SECTION 12 : DOOR 2 - issue_qr_token()  (admin's QR screen only)
--   The admin page calls this every ~20 s and redraws the QR.
--   Each token lives qr_valid_seconds (default 60 s).
-- ---------------------------------------------------------------------
create or replace function issue_qr_token(p_event_code text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
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
   where lower(event_code) = lower(trim(p_event_code)) and active;
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


-- ---------------------------------------------------------------------
-- SECTION 13 : Who may use which door
-- ---------------------------------------------------------------------
revoke all on function check_in(text, text, double precision, double precision, real, text, text) from public, anon, authenticated;
grant  execute on function check_in(text, text, double precision, double precision, real, text, text) to anon, authenticated;

revoke all on function issue_qr_token(text) from public, anon, authenticated;
grant  execute on function issue_qr_token(text) to authenticated;

revoke all on function is_admin() from public, anon, authenticated;
grant  execute on function is_admin() to authenticated;

commit;


-- DONE. Next: import staff.csv and events.csv, then run 02_after_import.sql
