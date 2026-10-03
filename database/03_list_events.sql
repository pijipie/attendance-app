-- =====================================================================
--  ATTENDANCE SYSTEM  -  03_list_events.sql
--  DOOR 3 : list_events()   (used by the staff page's event dropdown)
--
--  Paste this WHOLE file into Supabase > SQL Editor and press RUN (once).
--  Safe to run again: "create or replace" just overwrites the function.
--
--  WHY THIS IS NEEDED
--    Staff phones are not allowed to read the "events" table (that is the
--    lock we set in 01_schema.sql, Section 10). So the page cannot build a
--    dropdown by itself. This function is a small window in the wall: it
--    hands out ONLY what a dropdown needs and nothing else.
--
--  WHAT IT GIVES OUT (per active event)
--    event_code  : the value the page sends back to check_in()
--    name        : the text staff see in the dropdown
--    require_qr  : true  -> page tells staff to scan the QR at the location
--    open_now    : true  -> "now" is inside one of the event's time windows
--
--  WHAT IT NEVER GIVES OUT
--    latitude, longitude, radius, inactive events, staff, attendance.
-- =====================================================================

create or replace function list_events()
returns table (
  event_code  text,
  name        text,
  require_qr  boolean,
  open_now    boolean
)
language sql
stable                       -- it only reads, it never changes data
security definer             -- runs with the owner's rights, like check_in()
set search_path = public
as $$
  select e.event_code,
         e.name,
         e.require_qr,
         -- Same window test as check_in() step 3. If you ever change the
         -- rule there, change it here too, or the dropdown will disagree
         -- with the real decision. check_in() always has the final say.
         exists (
           select 1
             from event_windows w
            where w.event_id = e.id
              and (w.weekdays is null
                   or extract(isodow from t.local_now)::smallint = any (w.weekdays))
              and (w.starts_on is null or t.local_now::date >= w.starts_on)
              and (w.ends_on   is null or t.local_now::date <= w.ends_on)
              and t.local_now::time between w.start_time and w.end_time
         ) as open_now
    from events e
   cross join (select now() at time zone 'Asia/Kuala_Lumpur' as local_now) t
   where e.active
   order by e.name;
$$;


-- ---------------------------------------------------------------------
-- Who may use this door: everyone (staff phones are "anon").
-- First remove every default permission, then grant on purpose.
-- ---------------------------------------------------------------------
revoke all on function list_events() from public, anon, authenticated;
grant  execute on function list_events() to anon, authenticated;


-- ---------------------------------------------------------------------
-- Quick check: you should see one row per ACTIVE event (8 today),
-- with only the four columns above.
-- ---------------------------------------------------------------------
select * from list_events();


-- =====================================================================
--  LATER, BEFORE THE PILOT (do NOT run this now)
--  The two test events stay visible for now so you can test the new page.
--  When real staff start using it, hide them by removing the two dashes
--  in front of the next line and running only that line:
--
--  update events set active = false where event_code ilike 'TEST%';
-- =====================================================================
