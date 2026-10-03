# attendance-app — notes for Claude

Version 2 of the staff attendance system, rebuilding `attendance-geo-sraib` (Google Sheets + Apps Script) on Supabase. Still in development.

## Layout
- `index.html` — staff check-in page (BM/EN toggle). Calls the Supabase RPCs `list_events()` and `check_in(...)` using the **publishable** key, which is safe to be public.
- `database/` — all SQL, run in number order in the Supabase SQL Editor.
  - `01_schema.sql` — tables (`org_settings`, `staff`, `events`, `event_windows`, `admins`, `qr_tokens`, `attendance`), row-level security, and the functions `is_admin()`, `check_in()` and `issue_qr_token()`.
  - `02_after_import.sql` — run only after importing the staff and event CSVs into Supabase. It creates an "Anytime" window for each event.
  - `03_list_events.sql` — `list_events()`: active events for the dropdown (code, name, require_qr, open_now). Never exposes coordinates. Its time-window test must stay in sync with `check_in()`.

## Rules
- Public repo. Never commit staff names, CSV exports, venue coordinates, or any `service_role`/`sb_secret_` key.
- The CSVs used for the import are kept locally in `D:\Claude\Private Data\attendance\`, outside every repo.
- `anon` has no direct table access. Everything goes through `security definer` functions. Keep it that way, and grant execute only on purpose.
- UI text is in Bahasa Melayu with an English toggle; add every new message to both `ms` and `en`.
- Plain HTML/JS with no build step.
- Work on a branch and open a PR. Don't push straight to `main`.
