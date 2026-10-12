# Push notifications — build spec (version 0.9)

Written 11 Oct 2026, updated 12 Oct, for Claude Code on the maintainer's PC. Put this file in `docs/` and read it with `CLAUDE.md`, `PRODUCT.md` and `HANDOFF.md`. Every rule in `CLAUDE.md` still applies. Background and reasons: the "Push Notification Plan" doc in the claude.ai Project.

## 0. Decisions taken (maintainer, 11 Oct 2026)

| Decision | Choice |
|---|---|
| Who gets reminders | **Both.** Signing up is anonymous (general reminders). A phone becomes linked to a staff member at that person's first accepted check-in from that phone, and then also gets the "not yet" reminders. Never linked by typing a code. |
| First reminder | 06:30 Malaysian time |
| First release | **Small:** Remind me button + 3 reminders (R1, R2, R3 below). The rest come in a later version. |
| Admin view | A count of signed-up phones only. No names. |
| Release | Built and tested on the evening of Mon 12 Oct; timer on and announced Tue 13 Oct (section 8) |

## 1. Order of work

1. **Version 0.8 first:** `docs/step-out-0.8-spec.md` (the midnight fix plus time left today), SQL file 15. One pull request, one version.
2. **Version 0.9:** this spec, SQL file 16. (0.6.1 and 0.7 were released on 9 Oct, so the numbers moved up by one since the first draft of this spec.)

## 2. Reminders in this release

All times are worked out from the reminder event's sessions for that day (Daily Attendance, `0001`), never written as fixed clock times. No session that day (weekend, holiday) means no reminder.

| # | When | Goes to | BM | EN |
|---|---|---|---|---|
| R1 | 06:30, on days the event has a check-in session | Every signed-up phone | Kehadiran hari ini dibuka. Rekod sebelum {late_after}. | Today's attendance is open. Record before {late_after}. |
| R2 | Check-in session's `late_after` + 5 min (07:45) | Linked phones whose person has no accepted check-in today at **any** event (someone at an off-site briefing checked in there, so they are not nagged) | Kehadiran anda belum direkod. | Your attendance is not recorded yet. |
| R3 | Check-out session's `start_time` + 15 min (15:45, Friday 12:15) | Linked phones whose person checked in today, has no accepted check-out, and has not gone home through a step-out | Anda belum daftar keluar hari ini. | You have not checked out today. |

- R2 and R3 also skip anyone who is **not active** in `staff`, and R3 skips anyone whose only check-in today is at another event.
- The message language follows the language the phone used when it signed up.
- Lock-screen text never carries a name, a staff code or anyone else's status.
- Each phone gets each reminder at most once a day (`push_log`, below).
- Tapping a notification opens the staff page.
- Later versions (not now): 5 minutes before late, 10 minutes before check-out, check-out open, the two step-out reminders.

## 3. How it fits together

```
staff page --Remind me--> push_subscribe()  (public door: stores the push address)
staff page --after an accepted check-in--> push_link()  (public door: links address to that person)
pg_cron, every minute --> push_due()  (SQL: which reminders are due, to which phones, with what words)
       --pg_net POST--> Edge Function send-reminders  (signs with the VAPID private key, sends)
       <-- per-phone result: gone addresses (404/410) are deleted
phone: sw.js receives the push --> shows the notification --> tap opens the staff page
```

## 4. Database (new SQL file)

Follow the file conventions in `CLAUDE.md`: safe to run twice, guard added to the previous file, `revoke all` then grant on purpose, quick check at the end.

**Tables**

- `push_subscriptions`:
  - `id`, `endpoint` (unique; `https://` only; length limit, about 1,000);
  - `p256dh`, `auth` (length limits);
  - `device_id` (same format as `check_in()`'s);
  - `lang` (`ms` / `en`);
  - `staff_id` (empty until linked);
  - `created_at`, `linked_at`, `last_sent_at`, `fail_count`.
- `push_log`: `subscription_id`, `kind` (`R1`/`R2`/`R3`), `day`. Unique on all three, so a reminder can never go twice to one phone on one day.
- Both tables: no policies at all (like `qr_tokens`). Written only by the functions below, never readable through PostgREST.
- `org_settings`: add `push_event_id` (the event whose sessions drive the reminders). Default: the `0001` event if one exists. Owner-editable later; not needed in the admin page for this release.

**Public doors (anon)**

Same habits as `report_location_problem()`: measure every text before anything else, always answer `{"ok": true}`, keep a brake.

- `push_subscribe(endpoint, p256dh, auth, device_id, lang)`: insert, or update the keys if the address already exists. Never touches `staff_id` (re-subscribing keeps the link).
- `push_unsubscribe(endpoint)`: deletes the row, which removes the link too.
- `push_link(endpoint, device_id)`:
  - links the address only if an accepted (`present`) check-in today for the push event has exactly this `device_id`, and the subscription's own `device_id` is the same;
  - sets `staff_id` from that check-in, so a later check-in by someone else on the same phone moves the link to them;
  - anything else: stores nothing, same answer.
- Brake: at most 3 subscriptions per `device_id`, and 500 new subscriptions a day for the whole school.

**Admin door**

- `push_count()` → number of signed-up phones and number linked. `is_admin()` only. No list of names.

**Timer**

- `push_due(p_at timestamptz default now())` returns the reminders due at `p_at`: endpoint, keys, title, body, kind.
  - `p_at` exists so tests and the maintainer can try any time of day.
  - Write the `push_log` rows in the same step, so a reminder is never sent twice even if the timer runs late.
  - A reminder still goes out if the minute was missed, up to 15 minutes late; after that it is skipped.
- `cron.schedule` every minute → a small SQL function that calls `push_due()` and, only when something is due, POSTs the list to the Edge Function with `net.http_post`.
  - The call carries a shared secret header. The secret lives in Supabase Vault; never in the repository.
- `remove_event()`: the push tables do not point at `events`, so no change. `org_settings.push_event_id` must be cleared if that event is removed.

## 5. Edge Function `send-reminders`

- Deno, using the `web-push` npm package, server side only. Nothing loaded from a CDN in the pages.
- Checks the shared secret header first; anything else gets 401 and nothing is sent.
- Secrets, kept in Supabase Edge Function secrets and never in the repository: `VAPID_PRIVATE_KEY`, `VAPID_PUBLIC_KEY`, `VAPID_SUBJECT` (a `mailto:` address chosen by the maintainer), the shared secret.
- Sends each message with a TTL of about 30 minutes, so an old reminder is not shown in the afternoon.
- 404/410 from the push service → delete that subscription. Other failures → `fail_count` + 1; delete after 5 failures in a row.
- Logs counts only (sent, gone, failed), never addresses or names.

## 6. Website

**New files (repository root)**

- `sw.js` (service worker):
  - `push` → `showNotification(title, {body, icon: "logo.png", tag: kind, data: {url: "./"}})`;
  - `notificationclick` → focus an open staff page or open `./`.
  - No caching of pages (out of scope).
- `manifest.webmanifest`: name and short name (BM), `start_url: "./"`, `display: "standalone"`, theme colours from the shared colour variables, icons 192 and 512 px made from `logo.png`.
  - iPhone needs the manifest and the Home Screen icon for push at all.

**`index.html` (next staff page version)**

- `<link rel="manifest">`, and register `sw.js`.
- **Remind Me / Stop reminders button** under the counter. The label is exactly **Remind Me** in both languages, as announced to staff on 11 Oct; the stop label is "Hentikan peringatan" / "Stop reminders". It shows only when the browser has `serviceWorker`, `PushManager` and `Notification`.
- On an iPhone not opened from the Home Screen, tapping it shows one short message instead of asking: add the page to the Home Screen and open it from the icon. This is the only help text on the page; the maintainer asked to keep the page clean.
- The permission request happens **only inside the button's click**: a browser rule, and Apple's.
- After an accepted check-in (`reply.ok` in `check_in`), call `push_link()` quietly if this phone is signed up. Never block or delay the success message for it.
- One line beside the button, BM and EN, for example: "Peringatan membantu, tetapi tidak dijamin sampai. Simpan hanya alamat peranti ini; tekan Hentikan peringatan untuk memadam."
- Page and database in either order:
  - the button hides if `push_subscribe` answers 404;
  - nothing breaks if `sw.js` is missing.
- **Content-Security-Policy:** add `worker-src 'self'` and `manifest-src 'self'`; check that `script-src` allows `'self'` for `sw.js`. Nothing from other origins.

**`admin.html` (next admin page version)**

- One line in Settings, owner and manager: "Phones with reminders: 23 (18 linked)" from `push_count()`. Hidden when the door does not exist.

## 7. Tests

- **Database:** `push_due()` at fixed times, never "now":
  - 06:30, 07:45, 15:45 on a Monday;
  - R2 skips a person whose only check-in that day is at another event (an off-site briefing);
  - 12:15 on a Friday;
  - a Saturday (nothing due);
  - 20:30 on an evening event (the midnight lesson from 9 Oct).

  Also cover: once a day only; linking rules (wrong device, no check-in, another person's later check-in moves the link); doors answer the same for bad input; anon cannot read either table.
- **Browser:** button shown or hidden by browser support; the iPhone-not-from-Home-Screen message; subscribe and stop; `push_link` called after an accepted check-in only; the success message not delayed.
- **By hand, before release** (section 8): one Android phone in Chrome and one iPhone from the Home Screen.

## 8. Tuesday checklist (maintainer, with Claude Code)

**Done once in the Supabase dashboard** (cannot be done from this repository):

1. Database → Extensions: enable `pg_cron` and `pg_net`, if not already on. Claude Code should confirm the exact steps in the current Supabase docs.
2. Make the VAPID keys on the PC, for example `npx web-push generate-vapid-keys`. The **public** key goes into `index.html` (it is meant to be public). The **private** key goes only into Edge Function secrets.
3. Edge Functions → Secrets: add the four secrets from section 5.
4. Vault: store the same shared secret and the function's address for the timer.
5. Deploy `send-reminders`, with the Supabase CLI (logged in by the maintainer) or the dashboard editor.

**Release order**

1. Monday evening, first: 0.8 merged and SQL 15 run.
2. Monday evening, then:
   - run SQL 16 with the timer **paused**;
   - deploy the function;
   - merge the 0.9 pull request.
3. Monday evening, by hand: sign up the maintainer's own Android phone and an iPhone (Home Screen). Trigger a test send with `push_due('<a Monday 07:45>')` through an owner-only test door or the SQL Editor, and check both phones show it.
4. Tuesday morning: switch the timer on. The first R1 goes at 06:30 Wednesday if the timer is switched on after 06:30 Tuesday.
5. Tuesday: announce to staff (BM, previous style).
   - How to sign up: Remind me; on iPhone, Add to Home Screen first.
   - It is a help, not a guarantee.
   - What is kept: only the phone's address, linked at their own check-in.
   - How to stop.

## 9. Changelog lines (0.9, Major)

- Staff page: Remind me button; reminders at 06:30, after the late time for people not checked in, and after check-out opens for people not checked out.
- Database: push sign-ups, the once-a-day log, the timer.
- Admin page: count of phones with reminders.
- Decided: one button for both kinds of reminder; a phone is linked only by its own check-in; admins see a count, not names.
