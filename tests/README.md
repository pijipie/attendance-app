# Tests

Two kinds, both run on a computer, never against the live system.

| Folder | What it checks | How |
|---|---|---|
| `db/` | The SQL files: rules, refusals, who may read and write | A throw-away PostgreSQL 16 database with every file in `database/` installed, plus a fake of the Supabase parts (`supabase_stub.sql`) |
| `browser/` | `index.html` and `admin.html` | Playwright (Chromium) opens the page from this folder; every call to Supabase is answered by the test itself, and the phone's GPS is faked |

No staff names, staff codes (other than the published example MNHA) or real coordinates belong in this folder: the repository is public.

## Running

Linux or WSL, with Python 3, PostgreSQL 16 and Playwright for Python (`pip install playwright`, then `playwright install chromium`).

```bash
# database (as root)
bash tests/db/setup.sh && python3 tests/db/test_13_work_exits.py && python3 tests/db/test_15_step_out_time_left.py

# pages (any user); the argument is the folder that holds index.html and admin.html
for t in tests/browser/t_*.py; do python3 "$t" .; done
```

Each script prints PASS / FAIL per check and ends with "N of M passed".

| Script | Checks | Covers |
|---|---|---|
| `db/test_13_work_exits.py` | 54 | Stepping out: limits, latest time, location rules, manual return, read/write rights, archive |
| `db/test_15_step_out_time_left.py` | 41 | The midnight fix (fixed times, including 20:06 with the day ending at 21:00), time left today only on the phone that checked in, 225 then 210 after two 15-minute step-outs |
| `browser/t_staff.py` | 40 | Live location status, every location problem, problem reports |
| `browser/t_staff2.py` | 15 | Location-off events (silent), selected-staff events |
| `browser/t_staff3.py` | 46 | Attendance / Step out / Back in, messages in EN and BM |
| `browser/t_staff4.py` | 23 | Time left today: personal, general, out-now and gone-home notes in EN and BM, the extra line after Keluar / Masuk semula, an older database without file 15 |
| `browser/t_admin.py` | 13 | Rejected list incl. phone-side problems |
| `browser/t_admin2.py` | 32 | Location switch, invited staff picker, "Not on the list" |
| `browser/t_admin3.py` | 28 | Allow stepping out switch, Step-outs list, manual return, CSV |

## Known gaps

- `db/test_13_work_exits.py` builds its sessions around the computer's own clock, so it only runs between 03:00 and 17:59 Malaysian time, and evening times (after 20:00) are never tested. That is how the step-out midnight bug got through (see `HANDOFF.md`). New time-based tests should set the times they need instead of relying on "now".
- `db/test_15_step_out_time_left.py` tests the midnight fix on `exit_latest()` with fixed times, and checks that `work_exit()` and `exit_rules()` both use it. PostgreSQL's clock cannot be set from a test, so `work_exit()` itself is never run at 20:06. Its working day (00:01 to 23:58) lets it run at any hour from 00:02 to 19:30.
- Files 01 to 12 have no database test of their own yet.
