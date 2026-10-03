-- =====================================================================
--  RUN THIS ONLY AFTER you imported csv/staff.csv and csv/events.csv
--  Gives every event one "Anytime" window so check-ins work like the old
--  system (no time limit) until you set real times in event_windows.
-- =====================================================================

insert into event_windows (event_id, label, start_time, end_time)
select e.id, 'Anytime (migrated)', '00:00', '23:59:59'
from   events e
where  not exists (select 1 from event_windows w where w.event_id = e.id);

-- Quick health check: expect 70 staff, 8 events, 8 windows
select (select count(*) from staff)         as staff_rows,
       (select count(*) from events)        as event_rows,
       (select count(*) from event_windows) as window_rows;
