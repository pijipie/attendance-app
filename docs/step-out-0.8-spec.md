# Stepping out, version 0.8: midnight fix + "time left today"

Written 12 Oct 2026 for Claude Code on the maintainer's PC. Save as `docs/step-out-0.8-spec.md`. Every rule in `CLAUDE.md` still applies, except the one this spec changes on purpose (section 4). One pull request, one version (0.8), one SQL file (15).

## 1. What changes, in one line each

- **Fixed:** after 20:00 the latest return time wrapped past midnight (20:06 + 4 h = 00:06) and every return time was refused. School hours were never affected.
- **Added:** the phone that made today's check-in sees that person's real time left today ("Baki keluar hari ini: 2 j 29 min · paling lewat kembali 12:29") before pressing Submit, and after each Keluar / Masuk semula.

The 4-hour rule does not change: it stays **cumulative for the day** (confirmed by the maintainer, 12 Oct). Time away = actual Keluar to actual Masuk semula, seconds dropped. Going home counts to the end of the working day.

## 2. The midnight fix (in `work_exit()` and `exit_rules()`)

Today: `latest = least(now_minute + left minutes, work_end)` on `time` values. A `time` plus an interval wraps at midnight.

New, in both functions:

```
minutes_to_end := extract(epoch from (work_end - now_minute)) / 60   -- now_minute < work_end is already checked
allowed        := least(left, minutes_to_end)                          -- left = 240 - minutes used today
latest         := now_minute + make_interval(mins => allowed)          -- can never pass work_end, so never wraps
```

`limit_used_up`, `return_too_late`, `time_in_past` and the going-home over-limit logic keep their meaning and reply fields.

## 3. Time left, tied to the phone (never to a typed code)

**Why not by code:** the staff page is public. If typing a code showed someone's time left, anyone could type a colleague's code and learn whether that person stepped out today and for how long, and which codes exist.

**`exit_rules(p_event_code text, p_device_id text default null)`**

- Replaces the one-argument version: drop it and create this one. An old page calling with only `p_event_code` still works.
- Measure `p_device_id` first: the same length and format check as `check_in()`. A bad value is ignored, not an error.
- With no device ID, or when this device made no accepted check-in today: reply exactly as now (`ok`, `limit_minutes`, `work_start`, `work_end`, `now`, `open_now`, `latest` for someone not out yet today).
- When **this device** made today's accepted check-in to this event (`attendance.device_id = p_device_id`, `status = 'present'`, the `in` session, today), add for **that person only**:
  - `personal: true`;
  - `minutes_left`: 240 minus closed step-outs today, never below 0;
  - `latest`: worked out as in section 2 with that person's `minutes_left`;
  - `out_now: true` + `back_by`, when that person has an open step-out;
  - `gone_home: true`, when that person has gone home today.
- **Never** return a name, a staff code, a reason, or anything about another person or another day.

**`work_exit()` replies (new fields only; existing fields and `reason` words unchanged)**

- `out` accepted, not going home: `minutes_left_if_on_time` = minutes left if they are back at the written time.
- `back` accepted: `minutes_left` = max(0, 240 − `day_minutes`).

## 4. Rule change in `CLAUDE.md` (maintainer approved, 12 Oct 2026)

Replace "`exit_rules()` says nothing about any person: never add a staff code to it" with:

> `exit_rules()` may return the time left today only for the person whose accepted check-in today was made from the device ID it is given; nothing else about that person, and never anything found by a typed staff code. Without a matching device it answers the same for everyone.

Also: the 4-hour limit is still written in three places (`work_exit()`, `exit_rules()`, `work_exit_log`).

## 5. Staff page (index.html)

- `loadRules()` sends `p_device_id: deviceId()`.
  - If the database answers 404 or an argument error, the database is older than file 15: ask again without `p_device_id`, and stop sending it for this visit.
- The note under the time box, in this order:
  - `gone_home` → "Pulang sudah direkodkan hari ini." / "Going home is already recorded today."
  - `out_now` → "Anda masih di luar (kembali sebelum {back_by}). Pilih Masuk semula." / "You are still out (back by {back_by}). Choose Back in."
  - `personal` → "Baki keluar hari ini: {left} · paling lewat kembali {latest}" / "Time out left today: {left} · back by {latest} at the latest"
  - otherwise → the existing general sentence.
- `{left}` is written as "2 j 29 min" (BM) / "2 h 29 min" (EN), and "0 min" when nothing is left.
- Success messages get one more line when the field is present:
  - after Keluar: "Jika kembali pada {back}, baki hari ini {left}."
  - after Masuk semula: "Baki keluar hari ini: {left}."
- Refresh the note right after a successful Keluar or Masuk semula, as now.

## 6. Tests

**Database:** use fixed times, never the clock.

- An evening working day (20:00–21:00): Keluar at 20:06 with return 20:40 is accepted; 21:01 is refused with `latest` 21:00. This is the wrap case.
- Two step-outs of 15 minutes: `minutes_left` 225, then 210. The maintainer's example from 12 Oct.
- `exit_rules`:
  - with the device that made the check-in → personal fields;
  - with another device → general reply;
  - with no device → general reply;
  - with a bad device ID → general reply, no error.
- `out_now` and `gone_home` are shown only to the right device.
- The one-argument call still works.

**Browser:**

- Personal note, general note, out-now note, gone-home note, in EN and BM.
- An old database answering 404 to the two-argument call → the page asks again without the device ID and shows the general note.

## 7. Changelog (0.8, Major)

- **Fixed · Database:** the latest return time for stepping out was wrong after 8 pm (it went past midnight), so evening step-outs were refused. School hours were never affected.
- **Added · Staff page:** the phone that recorded today's attendance now shows the real time out left today, and the latest return time based on it. Other phones still see the general note.
- **Decided · All pages:** the 4-hour limit counts every step-out of the day together. The time left is shown only on the phone that made that day's check-in, never by typing a staff code.
