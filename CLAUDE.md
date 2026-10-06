# attendance-app — notes for Claude

Version 2 of the staff attendance system, rebuilding `attendance-geo-sraib` (Google Sheets + Apps Script) on Supabase. In pilot with real staff since 5 Oct 2026, so the database holds real attendance: treat every change as a change to a live system.

Read `PRODUCT.md` first. It holds the product facts and the open decisions.

## Layout
- `index.html` — staff check-in page. Calls the Supabase RPCs `list_events()`, `check_in(...)` and `event_counter(...)` with the **publishable** key, which is safe to be public.
- `admin.html` — admin page. Signs in through Supabase Auth, then reads and writes tables directly through PostgREST with the user's token. Row-level security decides what is allowed.
- `display.html` — no-login page for a big screen. Pairs with an admin through `display_register()` / `display_approve()` / `display_poll()`.
- `menu.js` — the three-line menu shared by every page. It holds the ONE list of pages (`PAGES`), and draws the light / dark button.
- `qrcode.js` — vendored third-party QR library (MIT). Never edit it.
- `leaflet.js`, `leaflet.css` — vendored third-party map library, Leaflet 1.9.4 (BSD-2-Clause). Never edit them. Only `admin.html` loads them.
- `logo.png`, `apple-touch-icon.png` — school logo.
- `database/01_schema.sql` … `database/10_work_hours.sql` — the database, in run order. A change to the database is always a NEW numbered file that is safe to run twice; never edit a file that has already been run. The one exception is the guard: every file except the newest starts with `begin;` and a `do` block that stops it when a later file is installed (re-running an old file would restore weaker functions and policies). When you add file N+1, add that guard (and the closing `commit;` before its quick check) to file N.

## Rules
- Public repo. Never commit staff names, CSV exports, venue coordinates, or any `service_role`/`sb_secret_` key.
- The CSVs used for the import are kept locally in `D:\Claude\Private Data\attendance\`, outside every repo.
- `anon` has no direct table access. Staff-phone features go through `security definer` functions. Revoke the default execute grant on every new function, then grant on purpose.
- `authenticated` holds only the table rights listed in `06_security_hardening.sql` PART F (for example `select` only on `attendance`, nothing on `admins` and `qr_tokens`). Supabase grants ALL on every new table by default: for a new table, `revoke all ... from anon, authenticated` and then grant exactly what the admin page needs.
- `check_in()` must give an unknown staff code the same reply a real one would get, must not store a row for it, and returns `distance_m` only with `ok` or `outside_geofence`. Every text input to a public function has a length limit checked before anything else.
- There must always be at least one owner while any admin exists. `admin_set()` / `admin_remove()` take a table lock, and the `admins_keep_owner` trigger is the backstop. Only accounts with a confirmed email can be made admins.
- A pairing code waits 5 minutes. That interval appears in `display_register()`, `display_approve()` and `display_poll()`: change all three together.
- `attendance` has a read policy only. Do not add write policies to it. Do not add any policy to `admins` or `qr_tokens`. `admin_audit` is read-only for owners; it is written only by the `audit_row()` trigger.
- Admin levels are `owner`, `manager`, `operator`. Reading uses `is_admin()`, writing uses `can_manage()`, settings and admin management use `is_owner()`. The page hides what a level cannot do, but the database is the real lock: never rely on the page.
- Never hard-delete an event or session that has attendance. Use `remove_event()` / `remove_window()`, which archive (`archived_at`) instead. Every query that feeds a staff-facing list or `check_in()` must skip archived rows.
- Any new table that admins can change needs the `audit_row()` trigger.
- `check_in()` and `list_events()` share the same time-window test. Change both together.
- Late is a stamp, never a refusal. A session is open from `start_time` to `end_time`; `late_after` (optional, inside those hours) only decides whether an ACCEPTED check-in gets `late_minutes`. The whole minute of `late_after` is on time. `late_minutes` is written once by `check_in()` and never recalculated, so editing a session later does not rewrite history. Only a `present` row may carry it.
- Hours worked: a session counts as check-in or check-out through `event_windows.counts_as` (`in`, `out`, or empty for an ordinary session). The `work_hours` view pairs them, one row per person, event and day: earliest accepted `in`, latest accepted `out`. The page never does the pairing or the sums; it shows what the view returns. Seconds are dropped before subtracting, the same as `late_minutes`.
- "In working hours" runs from the `in` session's `late_after` to the `out` session's `start_time`. There is no separate setting. It is worked out from the sessions as they are today, so editing a session's hours changes that figure for past days; the actual times never change. If that ever matters, store the two times on the row at check-in (like `radius_applied_m`) rather than adding a setting.
- A missing half is INCOMPLETE. Never fill in a default time, in SQL or in the page. An "assume they left at 15:30" switch for a missing check-out was built and then discarded on 6 Oct 2026: it would hide the people who leave before 15:30, and the school records those by hand even with its thumbprint devices. Do not propose it again. The only way to complete it is a manual time in `attendance_corrections`, added by an owner or manager with a reason. That table has insert and delete only (no update grant, no update policy). `correction_stamp()` overwrites `entered_by`, `entered_by_email` and `entered_at` whatever the page sends, refuses a time in the future (`fix_future`) and refuses a manual time beside a recorded check-in (`fix_already_recorded`). A recorded check-in always wins over a manual one in `work_hours`. Do not weaken any of this, and never write to `attendance` to "fix" a day.
- The admin page sends `counts_as` only when it is chosen or when the row already has the column, exactly like `late_after`, so the page works on a database without file 10. Keep that pattern for any new optional column. The Hours list only appears for an event that has a session with `counts_as`.
- The staff page does not remember the staff code: the box starts empty and shows the example. Do not bring the remembering back without asking; the event and the language are still remembered.
- The counter on the staff page, the display page and the admin QR screen counts ONE session, chosen by `counter_for()`: open now (started last), else finished last, else next to open. All three get it from the database (`event_counter()` for the staff and admin pages, `display_poll()` for the display); never count in the page. `check_in()` picks its session with `order by w.start_time desc, w.id`, which must stay the same as rule 1 in `counter_for()`.
- `event_counter()` is a PUBLIC door (no login). It may only ever return numbers and the session name. Never add names, staff codes, lists of who has or has not submitted, or anything about other days to it; build a separate admin-only function for that.
- The staff page must keep working if it and the SQL are deployed in either order. Add new reply fields; do not rename existing `reason` values.
- UI text exists in English and Bahasa Melayu. English is the default; a device that chose BM keeps BM. Every new string needs both.
- Every new page gets a line in `PAGES` in `menu.js` on the day it is created, and loads `menu.js` itself, so no page is ever unreachable while the layout is still being decided.
- A page must keep working if `menu.js` or the Leaflet files are missing (plain links instead of the menu; number boxes instead of the map).
- Text from the database goes into the page as text (`textContent`), never as HTML.
- Every page has a `Content-Security-Policy` meta tag and the small frame guard at the top of `<head>`. A new page gets both. If the database address or an outside service changes, change the `connect-src` / `img-src` lists too, or the page will be blocked from reaching it. Scripts stay inline for now, so `script-src` allows `'unsafe-inline'`; do not add any other source.
- The QR link is `…/?e=CODE#t=TOKEN`. The token stays in the fragment (never sent to a web server); `index.html` reads it, wipes it from the address bar and keeps it for the tab only. `?t=` is still read for old links; do not generate it.
- In `admin.html`, every reply from the database passes through `api()`, which throws it away if the person signed out meanwhile (`state.epoch`). Sign-out must empty the five views and the lists in `state`, not just hide them. Anything that draws starts with `if (!state.session) return;`.
- The attendance list is read in pages of 1,000 (`fetchAllRows`), present and rejected separately, filtered by event in the database. A failed load shows the error card; never draw an empty list after a failure.
- Plain HTML/CSS/JS with no build step. No code is loaded from a CDN: libraries are copied into the repo. The only outside services are OpenStreetMap map pictures and its Nominatim place search, used by the map in the admin event editor. Neither needs a key. Never send staff or attendance data to them.
- The admin page signs out after 15 minutes without a touch (`IDLE_MINUTES` in `admin.html`), on every screen including the QR screen. Long events use `display.html`.
- All three pages share one look: the colour variables at the top of each `<style>` block must stay identical.
- Light or dark is `<html data-theme>`, set by the script at the top of each page's `<head>` (identical in all three; it must stay in `<head>`, before the styles, so nothing flashes). Dark colours live under `:root[data-theme="dark"]`; do not bring back `@media (prefers-color-scheme)` for colours. Unless the device has chosen, `themeAuto()` picks light from 07:00 to 19:00 Malaysian time whatever the device prefers, because the staff page is used outdoors in sunlight and a dark page cannot be read there (reported from the pilot, 6 Oct 2026). `menu.js` draws the button and stores the choice as `theme` in localStorage; a choice equal to what `themeAuto()` would pick is removed, which returns the device to automatic. The button goes into `<div id="theme">` when a page has one (the staff page's title row, because its top row is full on a 360 px phone), otherwise beside the menu button.
- Work on a branch and open a PR. Don't push straight to `main`.

## Testing
- The maintainer runs SQL by hand in the Supabase SQL Editor and uploads files through the GitHub website.
- Do not sign in to the admin page on the maintainer's behalf, and never ask for the password.
