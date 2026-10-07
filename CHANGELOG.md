# Changelog

Everything that changed in the attendance system, newest first.

- **Who it is for:** the maintainer, the school's administrators, and anyone who takes the system over later.
- **A release** is a change merged into `main`. GitHub Pages publishes it within a few minutes.
- **Dates** are Malaysian time.
- **Each entry says** what changed for staff, for admins and in the database, which page versions it produced, and which SQL file it needs.
- **Groups:** Added (new), Changed (works differently), Fixed (was wrong), Security, and Decided (a choice worth remembering, with its reason).
- **How to keep it:** every pull request adds its lines under "Unreleased". When the pull request is merged, "Unreleased" becomes that day's heading. See `CLAUDE.md`.

Entries for 3 to 7 Oct 2026 were written on 7 Oct 2026 from the repository history, the version notes inside the pages and the SQL files.


## Unreleased

Planned for the evening of 8 Oct 2026. Staff page v2.9, admin page v3.8, SQL file `12_location_switch_invited_staff.sql`.

### Added
- **Admin page:** each event has a "Require location" switch, independent of "Require the QR scan". Switched off, no position is asked for, checked or stored for that event. The map, pin and radius are hidden but kept, and an event can be created with no pin at all.
- **Admin page:** a warning when location and QR are both off, because anyone with the link can then record attendance from anywhere during the event's hours.
- **Admin page:** an event can be for "All staff" or "Selected staff". For selected staff, the invited people are ticked from the staff list (search, filter by type, select or clear all shown).
- **Admin page:** for a selected-staff event, the counter reads "4 of 12", "Not checked in" lists only the invited, and the Present list and the CSV mark anyone who came without being on the list as "Not on the list".
- **Staff page:** someone who checks in to a selected-staff event without being on its list is still recorded and is told "Recorded, name not on the list". The page also says when an event is for invited staff.
- **Database:** `events.require_location`, `events.audience`, the `event_staff` table, `set_event_staff()` and `attendance.not_listed`. One line is written to the activity record each time an event's list changes.
- **This changelog.**

### Changed
- **Staff page:** for an event with location off, the page does not look for the phone and shows nothing about location. Staff are not told that location is off.
- **Database:** `check_in()` accepts a check-in without a position when the event does not require one, and answers `location_required` when one was needed and none was sent. `list_events()` also returns `require_location` and `audience`.
- **Database:** the pin of an event and the position columns of the attendance log may be empty, but only for an event with location off.


## 2026-10-07

Live location status. Pull request #13. Staff page v2.8, admin page v3.7, SQL file `11_location_problems.sql`.

Background: on the third pilot day, after the pilot was announced to staff, 16 staff tried to check in and 5 were never accepted. The analysis is in the project document "Location check-in analysis, 7 Oct 2026".

### Added
- **Staff page:** the page looks for the phone's position as soon as an event is chosen and shows how that is going on a line above the Submit button ("Location found ±12 m", "Weak signal", "Location is blocked"). A "Try again" button restarts the search.
- **Staff page:** each location problem has its own message: blocked, no location from the device, approximate location only, weak signal, not found.
- **Admin page:** the Rejected list, its count and the CSV also show the check-ins that the phone itself stopped because it had no position to send, marked "Device: ...".
- **Database:** the `location_problems` table and `report_location_problem()`. They record who was stuck, for which event, why and on which device. No position is stored.

### Changed
- **Staff page:** Submit sends the reading that is already waiting instead of searching for 12 hidden seconds afterwards. A reading older than 15 seconds is never sent.
- **Staff page:** "You are outside the area" also says to step outdoors so the phone can use GPS.
- **Staff page:** the location search stops when the page is out of sight, after a successful check-in, and after two idle minutes, to save battery.

### Fixed
- **Staff page:** a reading of hundreds of metres was reported as "GPS signal too weak, move to an open area". It now says that precise location is off.
- **Admin page:** a check-in that failed on the phone left no trace. It is now recorded.


## 2026-10-06

Hours worked (pull request #11) and light and dark mode (pull request #12). Admin page v3.5 and v3.6, SQL file `10_work_hours.sql`.

### Added
- **Admin page:** a session can be marked as check-in or check-out. The Attendance screen then has an Hours list: time in, time out, the actual length, the length inside working hours and the minutes late. The CSV gives the lengths in minutes.
- **Admin page:** an owner or manager can add a missing check-in or check-out time by hand, with a reason. It is always shown as manual, it is written to the activity record, and it can be removed but not edited.
- **All pages:** a sun and moon button switches between light and dark. The choice is remembered on that device.
- **Database:** `event_windows.counts_as`, the `attendance_corrections` table and the `work_hours` view.

### Changed
- **All pages:** every page opens light between 07:00 and 19:00 Malaysian time, even on a phone set to dark, because a dark page could not be read in sunlight during the pilot. At night it follows the device.

### Decided
- A day with a missing check-in or check-out is shown as incomplete. No time is ever assumed. An "assume they left at 15:30" switch was built and discarded the same day.


## 2026-10-05

The pilot with staff started. Session counter and staff counter (two direct commits), late stamp and staff filters (pull request #10). Staff page v2.6 and v2.7, admin page v3.3 and v3.4, SQL files `07_window_counter.sql`, `08_staff_counter.sql` and `09_late_stamp.sql`.

### Added
- **Staff page:** once an event is chosen, the counter of its session is shown under the Submit button ("Petang: 4 of 70 submitted") and renews itself every 20 seconds.
- **Staff page:** a check-in after the session's "late after" time is accepted and answered with "Recorded as late".
- **Admin page:** a session can have a "late after" time. The attendance list and the CSV show who was late and by how many minutes.
- **Admin page:** the staff list can be narrowed by type (staff, or intern and contract).

### Changed
- **Admin page and display page:** the counter follows the session (for example Pagi, Petang) instead of the whole day.
- **Staff page:** the staff code is no longer remembered. The box starts empty every time and shows "Example: MNHA".
- **Database:** late is a stamp, not a refusal. A check-in is refused only after the session ends.


## 2026-10-03

First day of the new system: the repository was created and nine pull requests were merged. Staff page up to v2.4, admin page up to v3.2, SQL files `01` to `06`.

### Added
- **Repository:** the first files, a corrected README (pull request #1), `.gitignore` and the project notes in `CLAUDE.md` (pull request #2).
- **Staff page v2:** the event is chosen from a list instead of typing a code, with a small EN / BM button. SQL moved into the `database/` folder, with `list_events()` (pull request #3).
- **Staff page:** the school logo on the page and on the browser tab, a floating notification for the answer, and a form that is never cleared after submitting. `PRODUCT.md` written (pull request #4).
- **Admin page:** sign in, show the rotating QR, read attendance (present, not checked in, rejected), manage events, hours and staff, and download a CSV. Refused duplicates are kept as rejected rows, with exact messages for "already recorded" and "device already used" (pull request #5).
- **Admin page:** three admin levels (owner, manager, operator), archive instead of delete, an activity record, and a no-login display page that an admin pairs from their own phone (pull request #6).
- **All pages:** a three-line menu listing every page. **Admin page:** a map for pinning an event's location (pull request #7).

### Changed
- **All pages:** English is the default language. A device that chose Bahasa Melayu keeps it (pull request #7).
- **Admin page:** sign-out after 15 minutes without a touch, on every screen (pull request #7).

### Fixed
- **Admin page:** sign-out now reaches the server even when the tab is closed straight afterwards (pull request #8).

### Security
- Fixes from the security review of 3 Oct 2026 (pull request #9): size limits and a brake on `check_in()`, replies that give less away, the QR secret moved to the part of the link that is never sent to a web server, table rights cut down to what the admin page uses, sign-out that empties the page, and an attendance list that loads every row and shows an error instead of "0 present".
