# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

## Users

- **Staff** of Sek. Ren. Islam Al-Irsyad Balok, about 70 people (permanent staff plus a few interns and contract staff). They record their own attendance on their own device while physically at the location. Phones are the main device; tablets and computers must also work.
- **Two situations of equal weight:** daily attendance at school, and separate events and programmes (meetings, courses, off-site activities).
- **Admins**, at three levels. An owner controls everything. A manager runs events, hours and staff. An operator only shows the QR and views attendance. Two or three admins are expected.
- **Maintainer:** one member of the school's staff who is not a professional programmer, can read code, and works through a browser with GitHub and Supabase.

## Product Purpose

Record who attended, where and when, with evidence, on a real database. It replaces the earlier Google Sheet and Apps Script system (v3, kept as a fallback) and the paper sign-in sheet.

The record serves three uses at once: the official attendance record, internal monitoring by management, and removal of the manual sheet. Because it is an official record, a wrong or missing entry has consequences for the person concerned.

Success means a staff member who is at the location can record attendance quickly on their own device, and a person who is not there cannot be recorded by someone else.

## Positioning

The database decides, not the page. The phone only reports measured facts (position, GPS accuracy, time, device, QR token) and one server function accepts or rejects them, keeping both outcomes as evidence. The anti-buddy-punching rule is "one device, one name, one event", backed by a rotating QR that can only be read at the location.

## Operating Context

- **Check-in flow:** open the page or scan the QR at the location, choose the event, allow location access, enter the staff code, submit, read the answer. The page starts looking for the phone's position as soon as the event is chosen and says how that is going on a line above the button ("Location found ±12 m", "Weak signal", "Location is blocked"), so a problem is seen before Submit, not after it.
- **Conditions:** used on arrival, often outdoors or at an entrance, on mobile data, where GPS needs open sky. The accuracy limit is 30 m and geofence radii are 30 to 50 m. Indoors a phone may place itself tens of metres away while claiming to be exact (it is using Wi-Fi, not GPS): the "outside the area" message therefore also says to step outdoors.
- **Light and dark:** every page opens light between 07:00 and 19:00 Malaysian time, even on a phone set to dark, because a dark page could not be read in sunlight during the pilot. At night it follows the device. A sun / moon button changes it and the choice is remembered on that device; on the staff page the button sits at the right end of the title, on the other pages beside the menu.
- **Languages:** English by default, Bahasa Melayu through a small EN/BM button. The choice is remembered on the device.
- **Moving between pages:** a three-line menu in the header of every page lists all pages. Every new page is added to it when it is created.
- **Hosting:** static pages on GitHub Pages from a public repository; data on Supabase (PostgreSQL), free tier.
- **Time zone:** Asia/Kuala_Lumpur for "today" and for all time windows.

## Capabilities and Constraints

**Staff page (`index.html`)**

- Event dropdown, BM/EN, and a typed-code fallback if the event list cannot be loaded.
- The answer appears as a floating notification; the form is never cleared.
- Server checks in this order: QR, time window, GPS accuracy, distance, then duplicates.
- Each location problem has its own words: blocked, no location from the device, approximate location only (a reading of hundreds of metres means precise location is off), weak signal, not found. A "Try again" button restarts the search.
- One check-in per person per session per day; one person per device per session per day.
- An event with "Require location" off: the page does not ask for location and the answer shows no distance. It says nothing about this: staff are not told that location can be switched off for an event.
- An event for selected staff: the page says it is for invited staff. Someone who is not on the list is still recorded and is told "Recorded, name not on the list".
- Late: a session can have a "late after" time between its start and end (morning session: start 03:00, late after 07:40, end 09:00). A check-in after it is accepted and stamped late with the minutes; the staff member is told "Recorded as late"; the attendance list and the CSV show the minutes. After the end time the attempt is refused and stored as rejected, as before. A session without a late time has no "late".
- The staff code box starts empty on every visit and shows "Example: MNHA". The code is not remembered on the phone; the chosen event and the language are.
- The staff list in the admin page can be narrowed by type (staff, or intern / contract) as well as by name, code and active or inactive.
- Check-out is a second session of the same event (for example Pagi for check-in, Petang for check-out). The counter on the staff page (under the Submit button, once an event is chosen), the display page and the admin QR screen counts one session at a time: the open one, else the one that finished last, else the next to open. It names the session ("Petang: 4 of 70 submitted") and starts again from 0 when the next session opens. An attempt outside every session is stored as rejected and belongs to no session.
- The counter on the staff page renews itself every 20 seconds while the page is on screen and straight after a submit. It is public: anyone who opens the staff page can see how many have submitted, but never who.
- A refused duplicate is kept as a rejected row, and the row for "device already used" shows whose device it was.
- Keluar waktu bekerja (stepping out during working hours): for an event that allows it, three choices appear under the event: Kehadiran (attendance), Keluar (step out), Masuk semula (back in). The choice starts on attendance every time.
  - Step out: only during working hours, only after a check-in that morning, and with the event's own location rules. The staff member writes their own reason (no list to pick from) and the time they will be back. The page shows the latest time allowed: now plus 4 hours, never later than the end of the working day; earlier step-outs that day shorten it. A later time is refused with the person's own latest time and what is left of their 4 hours.
  - "Not coming back today (going home)" is always recorded. It is the day's check-out in the Hours list, shown as "left early", and it is marked "over 4 hours" when the time out that day, counted to the end of working hours, passes 4 hours.
  - Back in: closes the open step-out. Coming back after the written time is recorded and marked late.
  - One open step-out at a time; nothing more can be recorded after going home. One device cannot record step-outs for two people on the same day.
  - Official duty outside the school is not a step-out: it is its own event.

**Admin page (`admin.html`)**

- Sign-in with a Supabase account that is listed in the `admins` table. The session lasts for the browser tab only, and ends by itself after 15 minutes without a touch on every screen, with a warning one minute before. Signing out ends that device's session only and empties the page.
- Three levels: owner, manager, operator. The database enforces them; the page only hides what a level cannot do.
- QR screen: a code that changes every 20 seconds, a live count of who is present, full-screen mode, a switch to require the QR for that event, and a button that opens the display page.
- Attendance: by date, event and session, with three lists (present, not checked in, rejected), GPS and device details, and CSV download. Every row of the day is loaded, however many; a failed load is shown as a failure, never as an empty list. At most 10 refused attempts per person are stored in any 10 minutes. The rejected list also shows the check-ins that the phone itself stopped because it had no position to send (location blocked, switched off, GPS did not answer), marked "Device: ..."; these carry no position and belong to no session.
- Hours worked: a session can be marked as check-in or check-out (the daily event: Pagi is check-in, Petang is check-out). The Attendance screen then has a fourth list, Hours, with one line per person: time in, time out, the actual length, the length inside working hours, and the minutes late. Both lengths are shown because both were asked for: in 06:58 and out 15:42 is 8 h 44 min actual and 7 h 50 min inside working hours (07:40 to 15:30). Working hours run from the check-in session's "late after" time to the moment the check-out session opens, so a day with its own sessions (Friday) has its own hours. The CSV gives the lengths in minutes.
- A missing check-in or check-out is shown as "No check-in" or "No check-out" and no length is worked out. Nothing is guessed. An owner or manager can add the missing time by hand with a reason (forgot, phone was flat, GPS failed). It is shown as manual with the reason and the account that entered it, it is written to the activity record, it can be removed but not edited, and it cannot replace a recorded check-in or lie in the future. There is no penalty for forgetting.
- Step-outs: an event has an "Allow stepping out during work" switch (off by default). It needs a check-in session with a late time and a check-out session, because working hours come from them; the editor warns when they are missing. The Attendance screen then has a fifth list, Step-outs: out, reason, back by (or "Going home"), back in, length, and marks for back, out, overdue (the written time has passed), went home, late and over 4 hours. Lengths and marks come from the database. An owner or manager can enter a forgotten return by hand ("came back at" a time, or "did not come back"), with a reason; it is marked manual and written to the activity record. The CSV gives the lengths in minutes.
- Events and attendance hours: add, change, remove; hours can repeat on chosen weekdays or cover chosen dates. Lists show current events by default, with search and an archive view.
- Two switches per event, independent of each other: "Require location" and "Require the QR scan". With location off no position is asked for or stored, the map, pin and radius are hidden but kept, and the event may have no pin at all. With both off, the editor warns that anyone with the link can record attendance from anywhere during the event's hours.
- Who an event is for: all staff, or selected staff ticked from the staff list (search, filter by type, select all shown). For a selected-staff event the counter reads "4 of 12", "Not checked in" lists only the invited, and anyone else who checks in is accepted and marked "Not on the list". The event still appears in every staff member's list of events, because the staff page has no login.
- Event location: set on a map (OpenStreetMap) by clicking, dragging the pin or searching for a place, with the allowed radius drawn as a circle. Latitude and longitude can still be typed.
- Staff: add, change, set inactive, remove. The list opens on active staff.
- Settings (owner): organisation name, GPS accuracy limit, QR lifetime, the other admins and their levels, and the activity record.

**Display page (`display.html`)**

- Shows the rotating QR on a big screen with no login. It shows a short code; an admin enters the code on their own signed-in phone, picks the event and a duration, and can stop it from the phone.
- It shows the event name and a head count only. It can read nothing else.

**Archive, not delete**

- Removing an event or session that already has attendance archives it. It leaves the staff page, the QR screen and the normal lists, cannot be checked in to, and can be restored. Its attendance rows keep their names.
- An archived event's code can be reused for a new event.
- Removing a staff member who has attendance sets them inactive.
- Things with no attendance are really deleted.

**Activity record**

- Every add, change and removal of staff, events, hours, settings and admins is recorded with who and when. Only an owner can read it. Nobody can edit it from the website.

**Deliberately not possible from the website**

- Changing or deleting an attendance row. The log is evidence. A time added by hand is kept in a separate table and is always labelled manual.
- Filling in a missing check-in or check-out automatically with a default time. Decided against on 6 Oct 2026: it would put a time nobody recorded into an official record. Assuming a 15:30 check-out for someone who forgot was also considered and discarded the same day: it would hide the people who leave early, who are recorded by hand.
- Creating an admin's account or password. That is done in Supabase; the page only assigns a level to an existing account.
- Leaving the system with no owner.
- Creating or dropping database tables. Structure changes go through numbered SQL files run in the Supabase SQL Editor.

**Planned**

- Real attendance hours entered for each event. Today every event is "anytime".
- QR switched on for the events that need it. Today it is off on every event.
- A staff "I forgot" request: the staff member asks from the staff page for a missing check-in or check-out to be added, and an admin approves or refuses it. Until then only an owner or manager can add a manual time.
- Later: linked-device binding, per-staff PIN, one-time passcodes.

**Decided against**

- A shared-device report.
- Checking step-outs against other events (for example refusing a step-out because the same person checked in to a meeting elsewhere). Decided against on 8 Oct 2026: the rule would need to know which events overlap and which are official duty, and a wrong refusal stops a real person. Each event keeps its own checks; an admin-only report can compare events later if it is ever needed.

**Constraints**

- Plain HTML, CSS and JavaScript with no build step. Libraries are copied into the repository, not loaded from elsewhere.
- The map depends on OpenStreetMap's free public servers, which give no guarantee of service. If they are unreachable, the location is typed as numbers.
- Free service tiers for now; a paid plan may come later for automation.
- Public repository: never commit staff names, CSV exports, venue coordinates or any secret key.
- The public key has no direct table access. Everything goes through database functions, and execute rights are granted on purpose.
- One person may own several devices.

**Terms used in the interface**

| Bahasa Melayu | English |
|---|---|
| Acara | Event |
| Kod staf | Staff code |
| Hantar kehadiran | Submit attendance |
| Kehadiran direkodkan | Attendance recorded |
| Di luar kawasan | Outside the area |
| Di luar waktu kehadiran | Outside attendance hours |
| Keluar waktu bekerja | Stepping out during working hours |
| Keluar | Step out |
| Masuk semula | Back in |
| Tidak kembali hari ini (pulang) | Not coming back today (going home) |

**Open decisions**

- Whether the school's official colours must be used.
- What the link to the official website (irsyadbalok.com.my) on the staff page becomes later; another plan for it is expected.
- Reporting across a date range (a month or a term). Today attendance is viewed one day at a time.
- Whether a formal accessibility standard applies.
- Final layout and position of the navigation. The three-line menu is the working arrangement until this is decided.
- A satellite (aerial photo) layer for the map. It would need a key from a map provider.
- Official duty: whether staff check in at school first and then go, or check in at the meeting place. To be asked of the office; either way it is a separate event, not a step-out.

## Brand Commitments

- The school is named on the page as "Sek. Ren. Islam Al-Irsyad Balok". The logo and name on the staff page link to the official website, https://irsyadbalok.com.my/.
- Interface text exists in both English and Bahasa Melayu, with English first.
- The school logo appears in the page header and as the browser tab icon, from a single `logo.png` beside the page.
- No colour or typeface has been made binding.

## Evidence on Hand

- Live staff page: https://pijipie.github.io/attendance-app/
- Source: `index.html`, `admin.html`, `display.html`, `menu.js`, `qrcode.js` (third-party, MIT), `leaflet.js` and `leaflet.css` (third-party, BSD-2-Clause), and the SQL files `database/01_schema.sql` to `database/10_work_hours.sql`, run in number order.
- A security and code review dated 3 Oct 2026, and the fixes for it in `06_security_hardening.sql` and page versions index 2.5, admin 3.2, display 1.2.
- A working database with the real staff list and six real events, plus test rows that must be removed before the pilot.
- One real phone test on 3 Oct 2026: one accepted check-in at 7 m, one rejected at 7,825 m.
- A pilot with real staff began on 5 Oct 2026. In its first two days seven staff tried the system, and on the first day three of six had both a check-in and a check-out, which is why a missing half is handled explicitly.
- The daily event keeps its 40 m radius after the pilot showed refusals at 41 m and 88 m: staff are expected to walk to the check-in point (decided 6 Oct 2026).
- Beyond that, there is no user feedback, no testimonials and no screenshots from real use yet. Do not invent any.

## Product Principles

1. The server decides. The page reports facts and shows the answer.
2. Presence is proven, not claimed.
3. Every answer says what happened and what to do next, in the person's language.
4. One non-specialist must be able to maintain it with a browser and free services.
5. Personal data stays out of the public repository and out of the public interface.

## Accessibility & Inclusion

- Must work on phone, tablet and computer.
- Must be usable in English and in Bahasa Melayu.
- No formal standard has been set.
