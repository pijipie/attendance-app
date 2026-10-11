# Handoff — 9 Oct 2026

Where the work stands, and what comes next, for the maintainer and for Claude Code working in this folder on the maintainer's PC. Read `CLAUDE.md` (the rules) and `PRODUCT.md` (the product facts) first; this file does not repeat them. Update this file at the end of each working session, or delete a section once it is done.

## 1. Where things stand

- **Live:** version 0.6 (staff page v2.10, admin page v3.9). SQL files 01 to 13 are installed; 13 was run on the evening of 9 Oct.
- **Pilot:** since 5 Oct, with real staff and the thumbprint machine still in use. 18 of 70 staff recorded on 9 Oct (13 the day before). No system errors; refusals were real (outside the circle, double presses) or phone-side ("location blocked").
- **Events in use:**
  - `0001` Daily Attendance: all staff, location on, 45 m circle at the front gate. Check-in session with late after 07:40, check-out session from 15:30 (Friday 12:00). Stepping out is **off**.
  - `0002` Mesyuarat Pentadbiran: 5 invited, Wednesdays 07:40–15:30, no late time.
  - `TEST00` Beacon Test: the maintainer's own evening test event. Stepping out is **on** here.
  - `TEST01` Beacon Test 2: 30 invited, 70 m circle covering the whole school, same hours as Daily Attendance (own Friday sessions). Collecting data for the pin decision.
- **Supabase project:** `xtrgefkopnqgektrllra`. Reading it is fine; any change goes through a numbered SQL file that the maintainer runs.

## 2. Work queue, in order

1. **Fix the step-out midnight bug (version 0.7, SQL file 14).**
   - `exit_rules()` and `work_exit()` compute the latest return time as `least(now_minute + 240 minutes, work_end)` on `time` values. After 20:00 the sum wraps past midnight (20:06 + 4 h = 00:06), so the latest time becomes 00:06 and every written return time is refused as `return_too_late`.
   - School hours never reach it (Daily Attendance ends at 15:30, so the sum stays below 19:30). Only evening events such as TEST00 are hit.
   - Fix: work out the minutes left until `work_end` first, take the smaller of that and what is left of the 240 minutes, then add it. The result can never pass `work_end`. `v_left`, `limit_used_up` and the `going_home` over-limit logic stay as they are.
   - New file `database/14_...sql` redefining both functions (safe to run twice), and the guard plus closing `commit;` added to file 13, as `CLAUDE.md` describes.
   - Add a database test that sets an evening working day (for example 20:00–21:00) instead of relying on the clock (`tests/README.md`, Known gaps).
   - Changelog: an SQL file makes it a Major line, so 0.7.
2. **Switch on stepping out for Daily Attendance**, after the maintainer has tested Step out and Back in himself on a school day. Then an announcement to staff (BM, the style of earlier announcements).
3. **Pin decision for Daily Attendance:** compare TEST01 (70 m) with 0001 (45 m) over next week. Distances of accepted and refused readings are in `attendance.distance_m`. The maintainer does not want the circle to cover ground outside the school (cars parked beside it); any circle that covers the whole L-shaped plot reaches outside the fence.
4. **Push notifications (version 0.8 or later).** Plan written 9 Oct (see section 7). Waiting on six decisions from the maintainer, the main one being anonymous or targeted reminders. Needs a service worker, an app manifest, a Supabase Edge Function, a timer and a new SQL file.
5. **How-to / FAQ page.** Notes in `docs/faq-notes.md`. The staff page itself gets no extra instructions.
6. **v3, cleaner code** (section 5).
7. **Small items:**
   - Remove the test manager account from Settings → Admins before more people use the admin page.
   - QR lifetime is 30 s; set it back to 60 s before QR is switched on for any event.
   - Mesyuarat Pentadbiran has no late time, so nobody is marked late; ask the maintainer whether that is intended.
   - Switch TEST00 and TEST01 off when testing ends.
   - Missing check-outs show as incomplete in Hours; an owner or manager adds known times by hand.
8. **Open decisions** in `PRODUCT.md`.

## 3. How the maintainer works

- Educator, not a programmer; reads code. Wants plain explanations in English, bullets, direct criticism, and a question before big actions. Staff-facing text in BM and English.
- Windows PC. Repository at `D:\Claude\GitHub\attendance-app`, used with GitHub Desktop. Private CSVs in `D:\Claude\Private Data\attendance\`, outside every repository.
- Runs every SQL file by hand in the Supabase SQL Editor, then pastes or describes the quick-check result.
- Every change: a branch, a pull request with its changelog lines, and the maintainer merges on GitHub.
- Releases in the evening, after school; checks the live log the next morning.

## 4. Working with Claude Code on the PC

- Open this folder in Claude Code; `CLAUDE.md` is read automatically. It is the source of truth for every rule; when a rule changes, change it there in the same pull request.
- Database: read with the Supabase connector or the SQL Editor. Never run a write against the live project; write a numbered SQL file instead.
- Tests: `tests/README.md`. On Windows they need WSL (Ubuntu) for PostgreSQL 16 and Playwright. Run the browser tests after any change to `index.html` or `admin.html`, and the database tests after any SQL file.
- Never commit staff names, staff codes other than MNHA, coordinates, CSV exports or any secret key. The publishable key in the pages is the only key that may be public.

## 5. v3: cleaner code (branch `v3`, same repository)

The maintainer chose a cleaner rebuild on a `v3` branch of this repository, with v2 staying live and receiving fixes only until v3 replaces it. Suggested approach: page by page, same database, each step deployable.

**What makes v2 hard to work on**

- `index.html` (about 1,260 lines) and `admin.html` (about 2,520 lines) each hold all their CSS, all their JavaScript and both languages inline.
- The colour variables, the light/dark script and the frame guard are copied into all three pages and must be kept identical by hand.
- Inline scripts force `script-src 'unsafe-inline'` in the Content-Security-Policy.
- Each SQL file that changes `check_in()` or `list_events()` repeats the whole function, so the current version of a function is only found in the newest file that touches it.
- The tests live in `tests/` but nothing runs them automatically.

**Directions for v3 (still to be agreed with the maintainer)**

- Shared files instead of copies: `theme.css` (colour tokens), `i18n.js` (EN/BM text), `api.js` (calls to Supabase), loaded by each page. Still no build step and no CDN.
- Scripts in files, so the CSP can drop `'unsafe-inline'`.
- A short `database/CURRENT.md` (or comments) saying which file holds the current version of each function.
- A GitHub Actions workflow that runs `tests/` on every pull request.
- Every rule in `CLAUDE.md` carries over unless the maintainer changes it.

## 6. Design handoff (Claude Design → Claude Code)

If v3 includes a new look, design it first in Claude Design, then hand the design to Claude Code to build on the `v3` branch. Brief for the designer:

- **Screens:**
  - Staff page: event, Attendance / Step out / Back in, staff code, reason and return time, location status line, Submit, counter, floating message.
  - Admin page: sign-in, QR screen, Attendance (Present, Not checked in, Rejected, Hours, Step-outs), Events (editor with map, switches, invited staff), Staff, Settings.
  - Display page: big-screen QR and head count.
- **Must hold:** works on a 360 px phone held outdoors in sunlight (light theme 07:00–19:00); BM and English; one set of colour tokens for all pages; the school logo; no fonts or code from a CDN; plain HTML, CSS and JavaScript.
- **Must not show:** the distance to the event before Submit, or any hint that an event can have location switched off.

## 7. Material outside this repository

In the claude.ai Project "Attendance System (Upgrade)":

- Location analysis, 7 Oct 2026. Contains the school outline coordinates: never copy them here.
- Security review, 3 Oct 2026.
- FAQ / how-to notes (also in `docs/faq-notes.md`).
- Push Notification Plan, 9 Oct 2026: reminder schedule, targeting and personal data, limits, decisions, reading list.
