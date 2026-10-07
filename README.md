# Attendance App

Geo-fenced staff attendance for Sek. Ren. Islam Al-Irsyad Balok.
Static pages on GitHub Pages, data on Supabase (PostgreSQL).

## Pages

| File | Who uses it | What it does |
|---|---|---|
| `index.html` | Staff | Record attendance: choose the event, enter the staff code, submit. |
| `admin.html` | Admins | Sign in, show the rotating QR, read attendance, manage events, hours, staff, settings and other admins. |
| `display.html` | A big screen | Shows the rotating QR with no login. An admin pairs it from their own phone with a short code. |
| `menu.js` | Every page | The three-line menu. It holds the one list of pages: add a line there whenever a page is created. It also draws the light / dark button. |
| `qrcode.js` | (library) | Draws the QR picture. Third-party code by Kazuhiko Arase, MIT licence. Do not edit. |
| `leaflet.js`, `leaflet.css` | (library) | Draws the map in the admin event editor. Third-party code, Leaflet 1.9.4, BSD-2-Clause licence. Do not edit. |
| `logo.png`, `apple-touch-icon.png` | (images) | School logo for the header, the browser tab and the iPhone home screen. |

## Database files

All SQL lives in the `database/` folder. Run each file once in Supabase > SQL Editor, in number order.

| File | What it builds |
|---|---|
| `01_schema.sql` | Tables, locks (row-level security), `check_in()`, `issue_qr_token()`, `is_admin()`. |
| `02_after_import.sql` | Run after importing staff and events. Gives every event an "anytime" window. |
| `03_list_events.sql` | `list_events()` for the staff page's event dropdown. |
| `04_admin.sql` | Write permissions for admins, and `check_in()` version 2, which keeps refused duplicates as rejected rows. |
| `05_roles_archive_displays.sql` | Three admin levels, archive instead of delete, the activity record, and screen pairing. |
| `06_security_hardening.sql` | Fixes from the security review of 3 Oct 2026: limits and a brake on `check_in()`, replies that give less away, confirmed accounts only for admins, never zero owners, pairing that cannot be jammed, table rights cut down, indexes. |
| `07_window_counter.sql` | The counter on the big screen and the admin QR screen follows the session (for example Pagi, Petang) instead of the whole day, so it starts again from 0 when check-out opens. `check_in()` now always picks the same session when two overlap. |
| `08_staff_counter.sql` | Opens `event_counter()` to staff phones, so the staff page can show the same counter under the Submit button. It gives numbers only: no names, no staff codes. |
| `09_late_stamp.sql` | A session can have a "late after" time. A check-in after it is still accepted until the session ends, and is stamped with the minutes late (`attendance.late_minutes`). Nothing behaves differently until an admin fills the time in. |
| `10_work_hours.sql` | Check-in is paired with check-out. A session can count as check-in or check-out; the `work_hours` view then gives one line per person per day with the time in, the time out, the actual length and the length inside working hours. A missing half is shown as incomplete, never filled in. An owner or manager can add the missing time by hand with a reason: it is kept in its own table (`attendance_corrections`), always labelled manual, and written to the activity record. Nothing behaves differently until an admin marks the sessions. |
| `11_location_problems.sql` | Check-ins that the phone itself stopped are recorded. When a phone can give no position at all (location blocked, switched off, GPS did not answer), the staff page reports it through `report_location_problem()` and the row is kept in `location_problems`: who, which event, which reason, which device, and no position. The admin page shows these in the Rejected list. Nothing else behaves differently. |

Each file from `01` to `10` begins with a guard: if a later file is already installed, it stops and changes nothing. Running an old file again would otherwise put back older, weaker rules. The newest file (`10`) is safe to run again.

## How the safety works

- The pages are public code. The database is what protects the data.
- Staff phones can only call four functions: `list_events()`, `check_in()`, `event_counter()` and `report_location_problem()`. They cannot read any table. `event_counter()` answers with numbers only (the session name, how many have submitted, how many active staff): never a name or a staff code. To close it again: `revoke execute on function event_counter(text) from anon;`
- The big screen can only call `display_register()` and `display_poll()`. It never holds a login.
- Admin requests carry a sign-in token. The database checks on every row that the person is in the `admins` table and what their level allows.
- Nobody can change or delete an attendance row from the website. A time added by hand is a separate, labelled row beside the log: it never replaces a recorded check-in, and the database itself writes who added it and when.
- An event or session that has attendance is archived, never deleted, so the log always keeps its names.
- Every change to staff, events, hours, settings and admins is written to an activity record that only an owner can read and nobody can edit.
- `check_in()` accepts only short, well-formed input, stores at most 10 refusals per person in any 10 minutes, and answers an unknown staff code exactly as it would answer a real one, so the reply cannot be used to find out which codes exist.
- A signed-in account holds only the table rights the admin page uses (for example, read-only on attendance). The row rules are a second lock on top, not the only one.
- Every page carries a Content-Security-Policy: it may load code only from its own folder and may talk only to the database (the admin page also to OpenStreetMap). No page can be shown inside another website's frame.
- The QR token travels after the `#` in the link, which is never sent to a web server, and the staff page wipes it from the address bar.

## Settings to check in Supabase (not in the code)

These cannot be set from a SQL file or from the pages. Check them once in the Supabase dashboard.

| Where | Setting | Why |
|---|---|---|
| Authentication > Sign In / Providers | **Allow new users to sign up: OFF** | Admin accounts are created by hand. With sign-up open, a stranger could register an address and wait for it to be added as an admin. `admin_set()` also refuses any account whose email is not confirmed. |
| Authentication > Attack Protection | **Leaked password protection: ON** (may need a paid plan) | Refuses passwords known from data breaches. |
| Database > Backups | The free plan keeps **no backups** | The attendance log is an official record. Download the CSV regularly from the Attendance screen, or move to a paid plan. |

## Outside services

- The map in the admin event editor shows pictures from OpenStreetMap and searches places with OpenStreetMap's Nominatim. Both are free and need no account or key.
- They are contacted only from the admin page, only while an event is being edited. They receive the part of the map being looked at and the words typed into the search box, nothing about staff or attendance.
- Map data © OpenStreetMap contributors. The credit on the map must stay.

## Light and dark

Every page opens light between 07:00 and 19:00 Malaysian time, even on a phone that is set to dark, because the staff page is read outdoors in sunlight. At night it follows the device. The sun / moon button changes it; the choice is remembered on that device, and pressing back to what the page would have picked returns it to automatic. The rule is the short `themeAuto` function at the top of each page's `<head>`.

## Signing out

The admin page signs out by itself after 15 minutes without a touch, on every screen, and warns one minute before. For a long event, show the QR with `display.html`, which has no login to lose.

Signing out ends the session on that device only (a phone signing out does not sign out a laptop), and empties the page: no staff list, attendance or admin email stays behind in the browser.

## Admin levels

| Level | Can do |
|---|---|
| Owner | Everything, including settings, the activity record and managing admins. |
| Manager | QR, attendance, and editing events, hours and staff. |
| Operator | Show the QR and view attendance. Cannot change anything. |

To add an admin: create the account in Supabase (Authentication > Users > Add user), then an owner enters that email under Settings > Admins and picks a level.

## Other documents

- `PRODUCT.md`: what the product is for, who uses it, what is decided and what is still open.
- `CLAUDE.md`: working rules for AI assistants editing this repository.

> **Do NOT commit staff names, CSV exports, venue coordinates or any secret / `service_role` key to this public repository.**
