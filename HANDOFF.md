# Handoff — 12 Oct 2026

Where the work stands, and what comes next, for the maintainer and for Claude Code working in this folder on the maintainer's PC. Read `CLAUDE.md` (the rules) and `PRODUCT.md` (the product facts) first; this file does not repeat them. Update this file at the end of each working session, or delete a section once it is done.

## 1. Where things stand

- **Live:** version 0.8 (staff page v2.12, admin page v3.10, display page v1.4). SQL files 01 to 15 are installed; 15 was run on the evening of 12 Oct. 0.8 fixed the step-out midnight bug and shows the time out left today on the phone that made the day's check-in. See `CHANGELOG.md`.
- **Pilot:** since 5 Oct, with real staff and the thumbprint machine still in use. Daily Attendance: 12 people on 8 Oct, 18 on 9 Oct, 15 on 12 Oct, out of 70 active staff. No system errors; refusals were real (outside the circle, weak GPS, double presses) or phone-side.
- **Phone-side problems are the main cause of trouble.** On 9 Oct, 4 people on 5 devices had location blocked for the page and 1 phone's GPS never answered; 3 of those 5 have no check-in that day and no manual time yet. 1 phone-side problem on 12 Oct. The fix for blocked location is in `docs/faq-notes.md`.
- **Stepping out:** on for Daily Attendance since 9 Oct 21:28. First school day, 12 Oct: 2 step-outs, both back (30 and 61 minutes), one back 3 minutes after the time written. None overdue, none over 4 hours.
- **Events in use:**
  - `0001` Daily Attendance: all staff, location on, 45 m circle at the front gate. Check-in session with late after 07:40, check-out session from 15:30 (Friday 12:00). Stepping out on.
  - `0002` Mesyuarat Pentadbiran: 5 invited, Wednesdays 07:40–15:30, no late time, 30 m circle.
  - `TEST00` Beacon Test (the maintainer's evening test event, stepping out on) and `TEST01` Beacon Test 2 (70 m circle, 30 invited): both switched **off** on 9 Oct 21:29. TEST01 collected one day of data (5 people on 9 Oct).
- **Settings:** GPS accuracy limit 30 m. QR lifetime 30 s. Admins: 1 owner, 1 manager (the test account).
- **Supabase project:** `xtrgefkopnqgektrllra`. `pg_cron` and `pg_net` are available but not switched on yet (needed for 0.9). Reading the database is fine; any change goes through a numbered SQL file that the maintainer runs.
- **Tests on this PC:** WSL (Ubuntu 26.04) with PostgreSQL 18, Python, Playwright and `faketime` since 12 Oct. How to run them: `tests/README.md` (use `PG_BIN=/usr/lib/postgresql/18/bin`; the checkout has Windows line endings, so run from a copy with `setup.sh` converted).

## 2. Work queue, in order

1. **Version 0.9: push reminders.** Spec: `docs/push-notifications-spec.md` (decisions taken 11 Oct). SQL file 16, a service worker, a manifest, an Edge Function, and the steps in the Supabase dashboard listed in the spec's section 8 (switch on `pg_cron` and `pg_net`, VAPID keys, secrets, Vault, deploy). Timer switched on and announced on Tue 13 Oct.
2. **Follow-up from 9 Oct.**
   - Attendance → 9 Oct → Rejected: the rows marked "Device: …" show the 3 people with no check-in. If they were at school, add a manual time with a reason in Hours.
   - Send staff the "location blocked" fix from `docs/faq-notes.md` (the iPhone / WhatsApp browser case).
3. **Stepping out, first week:** after school, look at Attendance → Step-outs; anything still "overdue" needs a manual return (owner or manager, with a reason).
4. **Pin decision for Daily Attendance:** compare TEST01 (70 m) with 0001 (45 m). TEST01 ran for one day only before it was switched off; switch it back on for a week if the comparison is still wanted. Distances of accepted and refused readings are in `attendance.distance_m`. The maintainer does not want the circle to cover ground outside the school (cars parked beside it); any circle that covers the whole L-shaped plot reaches outside the fence.
5. **How-to / FAQ page.** Notes in `docs/faq-notes.md`. The staff page itself gets no extra instructions.
6. **v3, cleaner code** (section 5).
7. **Small items:**
   - Remove the test manager account from Settings → Admins before more people use the admin page.
   - QR lifetime is 30 s; set it back to 60 s before QR is switched on for any event.
   - Mesyuarat Pentadbiran has no late time, so nobody is marked late; ask the maintainer whether that is intended.
   - Missing check-outs show as incomplete in Hours; an owner or manager adds known times by hand.
   - `tests/` has no database test for file 14 yet (the counter); `setup.sh` already installs it.
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

- `index.html` (about 1,270 lines) and `admin.html` (about 2,530 lines) each hold all their CSS, all their JavaScript and both languages inline.
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
