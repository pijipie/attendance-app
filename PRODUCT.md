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

- **Check-in flow:** open the page or scan the QR at the location, choose the event, enter the staff code, allow location access, submit, read the answer.
- **Conditions:** used on arrival, often outdoors or at an entrance, on mobile data, where GPS needs open sky. The accuracy limit is 30 m and geofence radii are 30 to 50 m.
- **Languages:** English by default, Bahasa Melayu through a small EN/BM button. The choice is remembered on the device.
- **Moving between pages:** a three-line menu in the header of every page lists all pages. Every new page is added to it when it is created.
- **Hosting:** static pages on GitHub Pages from a public repository; data on Supabase (PostgreSQL), free tier.
- **Time zone:** Asia/Kuala_Lumpur for "today" and for all time windows.

## Capabilities and Constraints

**Staff page (`index.html`)**

- Event dropdown, BM/EN, and a typed-code fallback if the event list cannot be loaded.
- The answer appears as a floating notification; the form is never cleared.
- Server checks in this order: QR, time window, GPS accuracy, distance, then duplicates.
- One check-in per person per session per day; one person per device per session per day.
- A refused duplicate is kept as a rejected row, and the row for "device already used" shows whose device it was.

**Admin page (`admin.html`)**

- Sign-in with a Supabase account that is listed in the `admins` table. The session lasts for the browser tab only, and ends by itself after 15 minutes without a touch on every screen, with a warning one minute before.
- Three levels: owner, manager, operator. The database enforces them; the page only hides what a level cannot do.
- QR screen: a code that changes every 20 seconds, a live count of who is present, full-screen mode, a switch to require the QR for that event, and a button that opens the display page.
- Attendance: by date, event and session, with three lists (present, not checked in, rejected), GPS and device details, and CSV download.
- Events and attendance hours: add, change, remove; hours can repeat on chosen weekdays or cover chosen dates. Lists show current events by default, with search and an archive view.
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

- Changing or deleting an attendance row. The log is evidence.
- Creating an admin's account or password. That is done in Supabase; the page only assigns a level to an existing account.
- Leaving the system with no owner.
- Creating or dropping database tables. Structure changes go through numbered SQL files run in the Supabase SQL Editor.

**Planned**

- Real attendance hours entered for each event. Today every event is "anytime".
- QR switched on for the events that need it. Today it is off on every event.
- Later: linked-device binding, per-staff PIN, one-time passcodes.

**Decided against**

- A shared-device report.

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

**Open decisions**

- Whether the school's official colours must be used.
- What the link to the official website (irsyadbalok.com.my) on the staff page becomes later; another plan for it is expected.
- Reporting across a date range (a month or a term). Today attendance is viewed one day at a time.
- Whether a formal accessibility standard applies.
- Final layout and position of the navigation. The three-line menu is the working arrangement until this is decided.
- A satellite (aerial photo) layer for the map. It would need a key from a map provider.

## Brand Commitments

- The school is named on the page as "Sek. Ren. Islam Al-Irsyad Balok". The logo and name on the staff page link to the official website, https://irsyadbalok.com.my/.
- Interface text exists in both English and Bahasa Melayu, with English first.
- The school logo appears in the page header and as the browser tab icon, from a single `logo.png` beside the page.
- No colour or typeface has been made binding.

## Evidence on Hand

- Live staff page: https://pijipie.github.io/attendance-app/
- Source: `index.html`, `admin.html`, `display.html`, `menu.js`, `qrcode.js` (third-party, MIT), `leaflet.js` and `leaflet.css` (third-party, BSD-2-Clause), and the SQL files `database/01_schema.sql` to `database/05_roles_archive_displays.sql`, run in number order.
- A working database with the real staff list and six real events, plus test rows that must be removed before the pilot.
- One real phone test on 3 Oct 2026: one accepted check-in at 7 m, one rejected at 7,825 m.
- There are no usage figures, user feedback, testimonials or screenshots from real use yet. Do not invent any.

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
