# Attendance App

Geo-fenced staff attendance for Sek. Ren. Islam Al-Irsyad Balok.
Static pages on GitHub Pages, data on Supabase (PostgreSQL).

## Pages

| File | Who uses it | What it does |
|---|---|---|
| `index.html` | Staff | Record attendance: choose the event, enter the staff code, submit. |
| `admin.html` | Admins | Sign in, show the rotating QR, read attendance, manage events, hours, staff and settings. |
| `qrcode.js` | (library) | Draws the QR picture. Third-party code by Kazuhiko Arase, MIT licence. Do not edit. |
| `logo.png`, `apple-touch-icon.png` | (images) | School logo for the header, the browser tab and the iPhone home screen. |

## Database files

All SQL lives in the `database/` folder. Run each file once in Supabase > SQL Editor, in number order.

| File | What it builds |
|---|---|
| `01_schema.sql` | Tables, locks (row-level security), `check_in()`, `issue_qr_token()`, `is_admin()`. |
| `02_after_import.sql` | Run after importing staff and events. Gives every event an "anytime" window. |
| `03_list_events.sql` | `list_events()` for the staff page's event dropdown. |
| `04_admin.sql` | Write permissions for admins, and `check_in()` version 2, which keeps refused duplicates as rejected rows. |

## How the safety works

- The pages are public code. The database is what protects the data.
- Staff phones can only call two functions: `list_events()` and `check_in()`. They cannot read any table.
- Admin requests carry a sign-in token. The database checks on every row that the person is in the `admins` table.
- Nobody can change or delete an attendance row from the website.
- Admins are added and removed in Supabase, never from the website.

## Other documents

- `PRODUCT.md`: what the product is for, who uses it, what is decided and what is still open.
- `CLAUDE.md`: working rules for AI assistants editing this repository.

> **Do NOT commit staff names, CSV exports, venue coordinates or any secret / `service_role` key to this public repository.**
