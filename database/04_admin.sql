-- =====================================================================
--  ATTENDANCE SYSTEM  -  04_admin.sql
--  What the admin page needs from the database.
--
--  Paste this WHOLE file into Supabase > SQL Editor and press RUN (once).
--  Safe to run again: every part first removes its old self.
--
--  PART A : admins may ADD, CHANGE and REMOVE staff, events and time
--           windows, and CHANGE the settings.
--  PART B : check_in() now keeps a row when it refuses a duplicate, so
--           the admin can see buddy-punching attempts.
--
--  What does NOT change
--    * Staff phones ("anon") still cannot read or write any table.
--    * Nobody, not even an admin, can change or delete an attendance row
--      from the website. The log is evidence.
--    * Only people listed in the "admins" table count as admins. Adding
--      or removing an admin is still done here in Supabase, on purpose.
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
    raise exception 'STOP: 05_roles_archive_displays.sql is already installed. Running this older file again would undo its stricter rules (operators could change staff, events and settings again). Nothing was changed.';
  end if;
end $$;


-- ---------------------------------------------------------------------
-- PART A : write permissions for admins
--   A "policy" is a rule the database checks on EVERY row.
--   01_schema.sql gave admins a READ rule. These are the WRITE rules.
--   is_admin() answers: "is the logged-in person in the admins table?"
-- ---------------------------------------------------------------------

-- A1. Staff : add, change, remove
drop policy if exists admin_insert on staff;
drop policy if exists admin_update on staff;
drop policy if exists admin_delete on staff;
create policy admin_insert on staff for insert to authenticated with check (is_admin());
create policy admin_update on staff for update to authenticated using (is_admin()) with check (is_admin());
create policy admin_delete on staff for delete to authenticated using (is_admin());

-- A2. Events : add, change, remove
drop policy if exists admin_insert on events;
drop policy if exists admin_update on events;
drop policy if exists admin_delete on events;
create policy admin_insert on events for insert to authenticated with check (is_admin());
create policy admin_update on events for update to authenticated using (is_admin()) with check (is_admin());
create policy admin_delete on events for delete to authenticated using (is_admin());

-- A3. Time windows : add, change, remove
drop policy if exists admin_insert on event_windows;
drop policy if exists admin_update on event_windows;
drop policy if exists admin_delete on event_windows;
create policy admin_insert on event_windows for insert to authenticated with check (is_admin());
create policy admin_update on event_windows for update to authenticated using (is_admin()) with check (is_admin());
create policy admin_delete on event_windows for delete to authenticated using (is_admin());

-- A4. Settings : change only (there is exactly one row; never add or remove)
drop policy if exists admin_update on org_settings;
create policy admin_update on org_settings for update to authenticated using (is_admin()) with check (is_admin());

-- Note on removing things:
--   A staff member, event or time window that already has attendance rows
--   CANNOT be removed. The database refuses, because the attendance rows
--   point at it. Switch it to "not active" instead. That is the safe way.


-- ---------------------------------------------------------------------
-- PART B : check_in() version 2
--   Same checks, same order: QR -> time window -> GPS accuracy -> distance.
--   NEW step 4b: if all of those pass, look for a duplicate BEFORE writing.
--     already_checked_in  : this person is already present for this session today
--     device_already_used : this phone already checked in SOMEONE ELSE for
--                           this session today  (the buddy-punching signal)
--   Both are now saved as a "rejected" row with that reason.
--
--   The phone still receives reason = 'duplicate_or_device_already_used'
--   (so an old copy of the page keeps working) plus a new field "detail"
--   that says which of the two it was.
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
  v_device    text := trim(p_device_id);
begin
  -- 0. basic sanity of what the phone sent
  if p_lat is null or p_lng is null or p_accuracy is null
     or p_lat not between -90 and 90 or p_lng not between -180 and 180
     or coalesce(length(v_device), 0) = 0 then
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
  --    (list_events() uses the same test. Keep the two the same.)
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

  -- 4b. NEW: everything passed, so check for a duplicate before writing
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
      -- Two phones pressed Submit in the same split second and the other
      -- one won. Rule A or Rule B stopped this one. Keep a row for it too.
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

-- "create or replace" keeps the old permissions, but say them again so
-- this file is complete by itself.
revoke all on function check_in(text, text, double precision, double precision, real, text, text) from public, anon, authenticated;
grant  execute on function check_in(text, text, double precision, double precision, real, text, text) to anon, authenticated;


commit;


-- ---------------------------------------------------------------------
-- Quick check: you should see exactly these 5 rows.
--   attendance     admin_read
--   event_windows  admin_delete, admin_insert, admin_read, admin_update
--   events         admin_delete, admin_insert, admin_read, admin_update
--   org_settings   admin_read, admin_update
--   staff          admin_delete, admin_insert, admin_read, admin_update
-- "attendance" must show ONLY admin_read. "admins" and "qr_tokens" must
-- not appear at all.
-- ---------------------------------------------------------------------
select tablename, string_agg(policyname, ', ' order by policyname) as policies
from   pg_policies
where  schemaname = 'public'
group  by tablename
order  by tablename;
