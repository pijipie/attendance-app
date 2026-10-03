# Attendance App

Geo-fenced staff attendance for Sek. Ren. Islam Al-Irsyad Balok.
Static pages on GitHub Pages, data on Supabase (PostgreSQL).

## Pages

| File | Who uses it | What it does |
|---|---|---|
| `index.html` | Staff | Record attendance: choose the event, enter the staff code, submit. |
| `admin.html` | Admins | Sign in, show the rotating QR, read attendance, manage events, hours, staff, settings and other admins. |
| `display.html` | A big screen | Shows the rotating QR with no login. An admin pairs it from their own phone with a short code. |
| `menu.js` | Every page | The three-line menu. It holds the one list of pages: add a line there whenever a page is created. |
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

## How the safety works

- The pages are public code. The database is what protects the data.
- Staff phones can only call two functions: `list_events()` and `check_in()`. They cannot read any table.
- The big screen can only call `display_register()` and `display_poll()`. It never holds a login.
- Admin requests carry a sign-in token. The database checks on every row that the person is in the `admins` table and what their level allows.
- Nobody can change or delete an attendance row from the website.
- An event or session that has attendance is archived, never deleted, so the log always keeps its names.
- Every change to staff, events, hours, settings and admins is written to an activity record that only an owner can read and nobody can edit.

## Outside services

- The map in the admin event editor shows pictures from OpenStreetMap and searches places with OpenStreetMap's Nominatim. Both are free and need no account or key.
- They are contacted only from the admin page, only while an event is being edited. They receive the part of the map being looked at and the words typed into the search box, nothing about staff or attendance.
- Map data © OpenStreetMap contributors. The credit on the map must stay.

## Signing out

The admin page signs out by itself after 15 minutes without a touch, on every screen, and warns one minute before. For a long event, show the QR with `display.html`, which has no login to lose.

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
