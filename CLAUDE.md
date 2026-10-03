# attendance-app — notes for Claude

Version 2 of the staff attendance system, rebuilding `attendance-geo-sraib` (Google Sheets + Apps Script) on Supabase. Still in development.

## Layout
- `index.html` — staff check-in page. Calls the Supabase RPC `check_in(...)` using the **publishable** key, which is safe to be public.
- `01_schema.sql` — tables (`org_settings`, `staff`, `events`, `event_windows`, `admins`, `qr_tokens`, `attendance`), row-level security, and the functions `is_admin()`, `check_in()` and `issue_qr_token()`.
- `02_after_import.sql` — run only after importing the staff and event CSVs into Supabase. It creates an "Anytime" window for each event.

## Rules
- Public repo. Never commit staff names, CSV exports, venue coordinates, or any `service_role`/`sb_secret_` key.
- The CSVs used for the import are kept locally in `D:\Claude\Private Data\attendance\`, outside every repo.
- `anon` has no direct table access. Everything goes through `security definer` functions. Keep it that way, and grant execute only on purpose.
- UI text is in Bahasa Melayu; keep new messages in Malay.
- Plain HTML/JS with no build step.
- Work on a branch and open a PR. Don't push straight to `main`.
