-- =====================================================================
--  ATTENDANCE SYSTEM  -  14_counter_active_staff.sql
--  The counter never says "13 of 12" (9 Oct 2026).
--
--  Paste this WHOLE file into Supabase > SQL Editor and press RUN (once).
--  Safe to run again. Needs file 13 first.
--
--  Why: the counter ("Petang: 4 of 70 submitted") counted "of 70" as the
--  ACTIVE staff (for a selected-staff event: the active people on its
--  list), but the "4" counted everyone who checked in, including someone
--  made inactive later that day. The two numbers could then disagree, and
--  a selected-staff event could show "13 of 12".
--  Now both numbers count active staff only.
--
--  PART A : counter_for()   - "present" counts active staff only
--  PART B : who may use which door
--
--  What does NOT change
--    * No attendance row is changed. The Present list on the admin page
--      still shows every check-in, active or not.
--    * Which session is counted, and everything else counter_for() does.
--    * The staff page, the display page and the admin QR screen get the
--      number from here as before, so all three follow at once.
-- =====================================================================

begin;      -- all or nothing: if any part fails, nothing in this file is kept

do $$
begin
  if to_regclass('public.work_exits') is null then
    raise exception 'STOP: run 13_work_exits.sql first. Nothing was changed.';
  end if;
end $$;


-- =====================================================================
-- PART A : counter_for()
--   counter_for() from 12_location_switch_invited_staff.sql, word for word,
--   plus the line marked "NEW in 14".
-- =====================================================================
create or replace function counter_for(p_event_id uuid) returns jsonb
language plpgsql stable set search_path = public as $$
declare
  v_local  timestamp := now() at time zone 'Asia/Kuala_Lumpur';
  v_now    time      := v_local::time;
  v_window event_windows%rowtype;
  v_selected boolean;                 -- true = this event is for selected staff only
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
                  join staff s on s.id = a.staff_id and s.active          -- NEW in 14: the same people "total" counts
                 where a.event_id = p_event_id and a.status = 'present'
                   and a.attendance_date = v_local::date
                   and (v_window.id is null or a.window_id = v_window.id)
                   -- for a selected-staff event, count only the people on its list
                   and (not v_selected or exists (select 1 from event_staff es
                                                   where es.event_id = p_event_id and es.staff_id = a.staff_id))),
    -- "of how many" is the list for a selected-staff event, everyone otherwise
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

-- A mark that this file is installed. The guard at the top of file 13 looks for it.
comment on function counter_for(uuid) is 'counter_for() from 14_counter_active_staff.sql';


-- =====================================================================
-- PART B : WHO MAY USE WHICH DOOR
-- =====================================================================
revoke all on function counter_for(uuid) from public, anon, authenticated;   -- inside helper: nobody calls it directly

commit;


-- ---------------------------------------------------------------------
-- Quick check. You should see one row for each event:
--   counter            = today's numbers; "present" is never above "total"
--   installed          = true
--   helper_is_closed   = true
-- ---------------------------------------------------------------------
select e.name as event,
       counter_for(e.id) as counter,
       obj_description('public.counter_for(uuid)'::regprocedure, 'pg_proc') like '%14_counter_active_staff%' as installed,
       not has_function_privilege('anon', 'public.counter_for(uuid)', 'execute')                         as helper_is_closed
from   events e
where  e.archived_at is null
order  by e.name;
