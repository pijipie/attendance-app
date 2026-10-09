# Changelog

Everything that changed in the attendance system, newest first.

- **Who it is for:** the maintainer, the school's administrators, and anyone who takes the system over later.
- **A release** is a change merged into `main`. GitHub Pages publishes it within a few minutes.
- **Dates** are Malaysian time.
- **Groups:** Added (new), Changed (works differently), Fixed (was wrong), Security, and Decided (a choice worth remembering, with its reason).
- **How to keep it:** every pull request adds its lines under the next version, marked "Unreleased". When the pull request is merged, the date replaces "Unreleased". See `CLAUDE.md`.

## How versions are numbered

| Number | Meaning | Example |
|---|---|---|
| `0.N` | The pilot. `N` goes up by one for every release that adds or changes a feature. | `0.4` to `0.5` |
| `0.N.P` | A release with fixes and small touches only. `P` goes up by one. | `0.5` to `0.5.1` |
| `1.0` | The pilot is over and the school uses the system officially. | |
| `2.0`, `3.0` | A rebuild that changes how the whole system is used. | |

The product version is separate from the version notes inside each page (staff page v2.x, admin page v3.x). Those count edits to one file; this counts releases of the whole system.

Every line is marked **Major** or **Minor**:

- **Major:** adds a feature, changes what staff or admins have to do, changes what the database stores, or needs an SQL file.
- **Minor:** a small improvement or correction that needs no instruction and no SQL file.

## Versions at a glance

| Version | Date | What | Pull requests | Pages | SQL files |
|---|---|---|---|---|---|
| 0.7 | 9 Oct 2026 | Counter counts active staff only | #17 | none | 14 |
| 0.6.1 | 9 Oct 2026 | Small fixes: QR screen counter, step-out messages, event save, big-screen bar | #16 | staff v2.11, admin v3.10, display v1.4 | none |
| 0.6 | 9 Oct 2026 | Keluar waktu bekerja (stepping out during working hours) | #15 | staff v2.10, admin v3.9 | 13 |
| 0.5 | 8 Oct 2026 | "Require location" switch; events for selected staff; this changelog | #14 | staff v2.9, admin v3.8 | 12 |
| 0.4 | 7 Oct 2026 | Live location status; phone-side failures recorded | #13 | staff v2.8, admin v3.7 | 11 |
| 0.3 | 6 Oct 2026 | Hours worked; manual times; light and dark | #11, #12 | admin v3.5, v3.6 | 10 |
| 0.2 | 5 Oct 2026 | Pilot starts; counters; late stamp; staff filter | #10 and two direct commits | staff v2.6, v2.7; admin v3.3, v3.4 | 07, 08, 09 |
| 0.1 | 3 Oct 2026 | First day: staff page, admin page, display page, security review | #1 to #9 | staff up to v2.4, admin up to v3.2 | 01 to 06 |

Versions 0.1 to 0.4 were numbered on 7 Oct 2026, after the fact, one per release day, from the repository history, the version notes inside the pages and the SQL files. From 0.5 onward every pull request gets its own number.


## 0.7 — 9 Oct 2026

Pull request #17, merged on the evening of 9 Oct 2026. No page changes. SQL file `14_counter_active_staff.sql` (run it after file 13).

### Fixed
- **Major · Database:** the counter ("Petang: 4 of 70 submitted") on the staff page, the big screen and the admin QR screen now counts only active staff in the first number, the same people it counts in "of 70". Before, someone made inactive after checking in was still counted, so a selected-staff event could show "13 of 12". The Present list still shows every check-in. Needs SQL file 14.


## 0.6.1 — 9 Oct 2026

Pull request #16, merged on the evening of 9 Oct 2026. Staff page v2.11, admin page v3.10, display page v1.4. No SQL file.

### Fixed
- **Minor · Admin page:** on the QR screen, the counter for a selected-staff event said "of 70" (every active staff member) instead of "of 12" (the invited list). It now uses the number the database gives, the same one the display page and the staff page show.
- **Minor · Staff page:** pressing Step out on a day with no working hours (a weekend) said "can only be recorded between  and ", with the two times missing. It now says there are no working hours today.
- **Minor · Admin page:** saving a selected-staff event now sends the invited list before switching the event over, so a failed save never leaves it set to "Selected staff" with the wrong list. A new event is no longer added a second time ("code already in use") when Save is pressed again after such a failure.
- **Minor · Admin page:** the big-screen display page keeps its countdown bar running when the language or full screen is switched, instead of stopping it until the next QR.

### Changed
- **Minor · Staff page:** when the phone gives no position during Step out or Back in, this is no longer reported to the admin's Rejected attendance list, where it looked like a failed check-in. The person still sees what went wrong.


## 0.6 — 9 Oct 2026

Keluar waktu bekerja. Pull request #15, merged on the evening of 9 Oct 2026. Staff page v2.10, admin page v3.9, SQL file `13_work_exits.sql` (run it after file 12).

### Added
- **Major · Staff page:** for an event that allows it, three choices appear under the event: Kehadiran, Keluar, Masuk semula (Attendance, Step out, Back in). Step out asks for the staff member's own reason, in their own words, and the time they will be back, or "Not coming back today (going home)". Back in closes it.
- **Major · Staff page:** under the time box the page shows the latest time to be back: now plus 4 hours, never after the end of the working day. A later time is refused, with that person's own latest time and the minutes they have left today.
- **Major · Admin page:** an "Allow stepping out during work" switch on each event, off by default. The editor warns when the event has no check-in session with a late time and no check-out session, because working hours come from them.
- **Major · Admin page:** the Attendance screen has a Step-outs list: out, reason, back by, back in, length, and marks for back, out, overdue, went home, late and over 4 hours. It is in the CSV too, with lengths in minutes.
- **Major · Admin page:** an owner or manager can enter a forgotten return by hand ("came back at" a time, or "did not come back"), with a reason. It is marked manual and written to the activity record.
- **Major · Database:** `events.allow_exit`, the `work_exits` table, the doors `work_exit()` and `exit_rules()` for staff phones, `exit_set_return()` for admins, and the `work_exit_log` view that works out every length and mark.

### Changed
- **Major · Database:** someone who goes home during working hours has that time as the day's check-out in the Hours list, shown as "left early". A check-out recorded at the check-out session still comes first.
- **Minor · Database:** an event that has step-outs on record is archived, not deleted, when it is removed.

### Decided
- **Minor · All pages:** the limit is 4 hours in one working day. Going home is always accepted and counts until the end of working hours; when that passes 4 hours the day is marked "over 4 hours" for the admin, and the school's leave rules take over.
- **Minor · All pages:** the reason is a free-text box, not a list to pick from.
- **Minor · All pages:** step-outs are not checked against other events. Such a rule would need to know which events overlap, and a wrong refusal would stop a real person. Official duty outside the school is its own event, not a step-out.


## 0.5 — 8 Oct 2026

Merged on the evening of 8 Oct 2026. Pull request #14. Staff page v2.9, admin page v3.8, SQL file `12_location_switch_invited_staff.sql`.

### Added
- **Major · Admin page:** each event has a "Require location" switch, independent of "Require the QR scan". Switched off, no position is asked for, checked or stored for that event. The map, pin and radius are hidden but kept, and an event can be created with no pin at all.
- **Major · Admin page:** an event can be for "All staff" or "Selected staff". For selected staff, the invited people are ticked from the staff list (search, filter by type, select or clear all shown).
- **Major · Admin page:** for a selected-staff event, the counter reads "4 of 12", "Not checked in" lists only the invited, and the Present list and the CSV mark anyone who came without being on the list as "Not on the list".
- **Major · Database:** `events.require_location`, `events.audience`, the `event_staff` table, `set_event_staff()` and `attendance.not_listed`. One line is written to the activity record each time an event's list changes.
- **Minor · Admin page:** a warning when location and QR are both off, because anyone with the link can then record attendance from anywhere during the event's hours.
- **Minor · Staff page:** someone who checks in to a selected-staff event without being on its list is still recorded and is told "Recorded, name not on the list". The page also says when an event is for invited staff.
- **Minor · Repository:** this changelog, with version numbers.

### Changed
- **Major · Database:** `check_in()` accepts a check-in without a position when the event does not require one, and answers `location_required` when one was needed and none was sent. `list_events()` also returns `require_location` and `audience`.
- **Minor · Staff page:** for an event with location off, the page does not look for the phone and shows nothing about location. Staff are not told that location is off.
- **Minor · Database:** the pin of an event and the position columns of the attendance log may be empty, but only for an event with location off.


## 0.4 — 7 Oct 2026

Live location status. Pull request #13. Staff page v2.8, admin page v3.7, SQL file `11_location_problems.sql`.

Background: on the third pilot day, after the pilot was announced to staff, 16 staff tried to check in and 5 were never accepted. The analysis is in the project document "Location check-in analysis, 7 Oct 2026".

### Added
- **Major · Staff page:** the page looks for the phone's position as soon as an event is chosen and shows how that is going on a line above the Submit button ("Location found ±12 m", "Weak signal", "Location is blocked"). A "Try again" button restarts the search.
- **Major · Admin page:** the Rejected list, its count and the CSV also show the check-ins that the phone itself stopped because it had no position to send, marked "Device: ...".
- **Major · Database:** the `location_problems` table and `report_location_problem()`. They record who was stuck, for which event, why and on which device. No position is stored.
- **Minor · Staff page:** each location problem has its own message: blocked, no location from the device, approximate location only, weak signal, not found.

### Changed
- **Major · Staff page:** Submit sends the reading that is already waiting instead of searching for 12 hidden seconds afterwards. A reading older than 15 seconds is never sent.
- **Minor · Staff page:** "You are outside the area" also says to step outdoors so the phone can use GPS.
- **Minor · Staff page:** the location search stops when the page is out of sight, after a successful check-in, and after two idle minutes, to save battery.

### Fixed
- **Major · Admin page:** a check-in that failed on the phone left no trace, so nobody could tell who had tried. It is now recorded.
- **Minor · Staff page:** a reading of hundreds of metres was reported as "GPS signal too weak, move to an open area". It now says that precise location is off.


## 0.3 — 6 Oct 2026

Hours worked (pull request #11) and light and dark mode (pull request #12). Admin page v3.5 and v3.6, SQL file `10_work_hours.sql`.

### Added
- **Major · Admin page:** a session can be marked as check-in or check-out. The Attendance screen then has an Hours list: time in, time out, the actual length, the length inside working hours and the minutes late. The CSV gives the lengths in minutes.
- **Major · Admin page:** an owner or manager can add a missing check-in or check-out time by hand, with a reason. It is always shown as manual, it is written to the activity record, and it can be removed but not edited.
- **Major · Database:** `event_windows.counts_as`, the `attendance_corrections` table and the `work_hours` view.
- **Minor · All pages:** a sun and moon button switches between light and dark. The choice is remembered on that device.

### Changed
- **Minor · All pages:** every page opens light between 07:00 and 19:00 Malaysian time, even on a phone set to dark, because a dark page could not be read in sunlight during the pilot. At night it follows the device.

### Decided
- A day with a missing check-in or check-out is shown as incomplete. No time is ever assumed. An "assume they left at 15:30" switch was built and discarded the same day.


## 0.2 — 5 Oct 2026

The pilot with staff started. Session counter and staff counter (two direct commits), late stamp and staff filters (pull request #10). Staff page v2.6 and v2.7, admin page v3.3 and v3.4, SQL files `07_window_counter.sql`, `08_staff_counter.sql` and `09_late_stamp.sql`.

### Added
- **Major · Staff page:** a check-in after the session's "late after" time is accepted and answered with "Recorded as late".
- **Major · Admin page:** a session can have a "late after" time. The attendance list and the CSV show who was late and by how many minutes.
- **Minor · Staff page:** once an event is chosen, the counter of its session is shown under the Submit button ("Petang: 4 of 70 submitted") and renews itself every 20 seconds.
- **Minor · Admin page:** the staff list can be narrowed by type (staff, or intern and contract).

### Changed
- **Major · Database:** late is a stamp, not a refusal. A check-in is refused only after the session ends.
- **Minor · Admin page and display page:** the counter follows the session (for example Pagi, Petang) instead of the whole day.
- **Minor · Staff page:** the staff code is no longer remembered. The box starts empty every time and shows "Example: MNHA".


## 0.1 — 3 Oct 2026

First day of the new system: the repository was created and nine pull requests were merged. Staff page up to v2.4, admin page up to v3.2, SQL files `01` to `06`.

### Added
- **Major · Staff page:** version 2 of the page. The event is chosen from a list instead of typing a code, with a small EN / BM button. SQL moved into the `database/` folder, with `list_events()` (pull request #3).
- **Major · Admin page:** sign in, show the rotating QR, read attendance (present, not checked in, rejected), manage events, hours and staff, and download a CSV. Refused duplicates are kept as rejected rows, with exact messages for "already recorded" and "device already used" (pull request #5).
- **Major · Admin page:** three admin levels (owner, manager, operator), archive instead of delete, an activity record, and a no-login display page that an admin pairs from their own phone (pull request #6).
- **Major · Admin page:** a map for pinning an event's location (pull request #7).
- **Minor · Staff page:** the school logo on the page and on the browser tab, a floating notification for the answer, and a form that is never cleared after submitting. `PRODUCT.md` written (pull request #4).
- **Minor · All pages:** a three-line menu listing every page (pull request #7).
- **Minor · Repository:** the first files, a corrected README (pull request #1), `.gitignore` and the project notes in `CLAUDE.md` (pull request #2).

### Changed
- **Minor · All pages:** English is the default language. A device that chose Bahasa Melayu keeps it (pull request #7).
- **Minor · Admin page:** sign-out after 15 minutes without a touch, on every screen (pull request #7).

### Fixed
- **Minor · Admin page:** sign-out now reaches the server even when the tab is closed straight afterwards (pull request #8).

### Security
- **Major:** fixes from the security review of 3 Oct 2026 (pull request #9): size limits and a brake on `check_in()`, replies that give less away, the QR secret moved to the part of the link that is never sent to a web server, table rights cut down to what the admin page uses, sign-out that empties the page, and an attendance list that loads every row and shows an error instead of "0 present".
