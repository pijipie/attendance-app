# attendance-app — notes for Claude

Version 2 of the staff attendance system, rebuilding `attendance-geo-sraib` (Google Sheets + Apps Script) on Supabase. Still in development; not yet piloted with real staff.

Read `PRODUCT.md` first. It holds the product facts and the open decisions.

## Layout
- `index.html` — staff check-in page. Calls the Supabase RPCs `list_events()` and `check_in(...)` with the **publishable** key, which is safe to be public.
- `admin.html` — admin page. Signs in through Supabase Auth, then reads and writes tables directly through PostgREST with the user's token. Row-level security decides what is allowed.
- `qrcode.js` — vendored third-party QR library (MIT). Never edit it.
- `logo.png`, `apple-touch-icon.png` — school logo.
- `database/01_schema.sql` … `database/04_admin.sql` — the database, in run order. A change to the database is always a NEW numbered file that is safe to run twice; never edit a file that has already been run.

## Rules
- Public repo. Never commit staff names, CSV exports, venue coordinates, or any `service_role`/`sb_secret_` key.
- The CSVs used for the import are kept locally in `D:\Claude\Private Data\attendance\`, outside every repo.
- `anon` has no direct table access. Staff-phone features go through `security definer` functions. Revoke the default execute grant on every new function, then grant on purpose.
- `attendance` has a read policy only. Do not add write policies to it. Do not add any policy to `admins` or `qr_tokens`.
- `check_in()` and `list_events()` share the same time-window test. Change both together.
- The staff page must keep working if it and the SQL are deployed in either order. Add new reply fields; do not rename existing `reason` values.
- UI text exists in Bahasa Melayu and English, Bahasa Melayu first. Every new string needs both.
- Text from the database goes into the page as text (`textContent`), never as HTML.
- Plain HTML/CSS/JS with no build step and no CDN dependencies.
- Both pages share one look: the colour variables at the top of each `<style>` block must stay identical.
- Work on a branch and open a PR. Don't push straight to `main`.

## Testing
- The maintainer runs SQL by hand in the Supabase SQL Editor and uploads files through the GitHub website.
- Do not sign in to the admin page on the maintainer's behalf, and never ask for the password.
