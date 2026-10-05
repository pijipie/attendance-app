-- =====================================================================
--  ATTENDANCE SYSTEM  -  08_staff_counter.sql
--  The counter is also shown on the staff page (5 Oct 2026).
--
--  Paste this WHOLE file into Supabase > SQL Editor and press RUN (once).
--  Safe to run again.
--
--  Why: when a staff member picks an event, the page shows the same line
--  as the big screen under the Submit button ("Petang: 4 of 70
--  submitted"). The number moves by itself, so people can see that the
--  system is alive before and after they press Submit.
--
--  PART A : event_counter()  - opened to staff phones (no login)
--  PART B : who may use which door
--
--  What does NOT change
--    * No table, no column, no row. One function is replaced.
--    * counter_for(), display_poll() and check_in() are not touched.
--    * The admin QR screen keeps working exactly as it does now.
--
--  WHAT BECOMES PUBLIC - read this once
--    Until now only an admin (07) or a paired big screen could ask for
--    the counter. After this file, anyone who opens the staff page can.
--    What they can learn, for an event that is in the dropdown anyway:
--      the session name, whether it is open, how many people have
--      submitted, and how many active staff there are in all.
--    What they can NOT learn: any name, any staff code, who has or has
--    not submitted, any location, anything about past days.
--    To close it again later, run this one line:
--      revoke execute on function event_counter(text) from anon;
--    (The staff page then simply shows no counter. Nothing else breaks.)
-- =====================================================================

begin;      -- all or nothing: if any part fails, nothing in this file is kept


-- =====================================================================
-- PART A : event_counter() version 2
--   Version 1 (07_window_counter.sql, PART C) was for admins only.
--   Version 2 answers anyone, because the staff page has no login.
--   The counting itself is still done by counter_for(): ONE rule for the
--   big screen, the admin QR screen and the staff page.
--
--   Two other changes, both because this is now a public door:
--     * The length of the event code is checked before anything else
--       (the rule for every public function).
--     * An unknown, switched-off or archived event gets an empty answer
--       (null) instead of an error. The pages treat "no answer" as
--       "show no counter".
-- =====================================================================
create or replace function event_counter(p_event_code text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_event_id uuid;
begin
  if coalesce(length(p_event_code), 0) not between 1 and 60 then
    return null;
  end if;

  select id into v_event_id from events
   where lower(event_code) = lower(trim(p_event_code)) and active and archived_at is null;
  if v_event_id is null then
    return null;
  end if;

  return counter_for(v_event_id);      -- present, total, window_label, window_state
end;
$$;


-- =====================================================================
-- PART B : WHO MAY USE WHICH DOOR
--   Take the default "everyone may call it" away first, then give on purpose.
--   counter_for() stays an inside helper: no page can call it directly.
-- =====================================================================
revoke all on function event_counter(text) from public, anon, authenticated;

-- staff phones (no login) and signed-in admins
grant execute on function event_counter(text) to anon, authenticated;

commit;


-- ---------------------------------------------------------------------
-- Quick check. You should see one row for each active event:
--   staff_page_can_ask = true
--   helper_is_closed   = true   (counter_for() itself is still not public)
--   counter            = the same numbers the big screen shows
-- ---------------------------------------------------------------------
select e.event_code, e.name,
       has_function_privilege('anon', 'public.event_counter(text)', 'execute')     as staff_page_can_ask,
       not has_function_privilege('anon', 'public.counter_for(uuid)', 'execute')   as helper_is_closed,
       event_counter(e.event_code)                                                  as counter
from   events e
where  e.active and e.archived_at is null
order  by e.name;
