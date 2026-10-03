# attendance-app — notes for Claude

Version 2 of the staff attendance system, rebuilding `attendance-geo-sraib` (Google Sheets + Apps Script) on Supabase. Still in development; not yet piloted with real staff.

Read `PRODUCT.md` first. It holds the product facts and the open decisions.

## Layout
- `index.html` — staff check-in page. Calls the Supabase RPCs `list_events()` and `check_in(...)` with the **publishable** key, which is safe to be public.
- `admin.html` — admin page. Signs in through Supabase Auth, then reads and writes tables directly through PostgREST with the user's token. Row-level security decides what is allowed.
- `display.html` — no-login page for a big screen. Pairs with an admin through `display_register()` / `display_approve()` / `display_poll()`.
- `qrcode.js` — vendored third-party QR library (MIT). Never edit it.
- `logo.png`, `apple-touch-icon.png` — school logo.
- `database/01_schema.sql` … `database/05_roles_archive_displays.sql` — the database, in run order. A change to the database is always a NEW numbered file that is safe to run twice; never edit a file that has already been run.

## Rules
- Public repo. Never commit staff names, CSV exports, venue coordinates, or any `service_role`/`sb_secret_` key.
- The CSVs used for the import are kept locally in `D:\Claude\Private Data\attendance\`, outside every repo.
- `anon` has no direct table access. Staff-phone features go through `security definer` functions. Revoke the default execute grant on every new function, then grant on purpose.
- `attendance` has a read policy only. Do not add write policies to it. Do not add any policy to `admins` or `qr_tokens`. `admin_audit` is read-only for owners; it is written only by the `audit_row()` trigger.
- Admin levels are `owner`, `manager`, `operator`. Reading uses `is_admin()`, writing uses `can_manage()`, settings and admin management use `is_owner()`. The page hides what a level cannot do, but the database is the real lock: never rely on the page.
- Never hard-delete an event or session that has attendance. Use `remove_event()` / `remove_window()`, which archive (`archived_at`) instead. Every query that feeds a staff-facing list or `check_in()` must skip archived rows.
- Any new table that admins can change needs the `audit_row()` trigger.
- `check_in()` and `list_events()` share the same time-window test. Change both together.
- The staff page must keep working if it and the SQL are deployed in either order. Add new reply fields; do not rename existing `reason` values.
- UI text exists in Bahasa Melayu and English, Bahasa Melayu first. Every new string needs both.
- Text from the database goes into the page as text (`textContent`), never as HTML.
- Plain HTML/CSS/JS with no build step and no CDN dependencies.
- All three pages share one look: the colour variables at the top of each `<style>` block must stay identical.
- Work on a branch and open a PR. Don't push straight to `main`.

## Testing
- The maintainer runs SQL by hand in the Supabase SQL Editor and uploads files through the GitHub website.
- Do not sign in to the admin page on the maintainer's behalf, and never ask for the password.
