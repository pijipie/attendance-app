# Notes for the future How-to / FAQ page

Collected from the pilot. Not built yet. Decision 9 Oct 2026: the staff page itself stays clean, with no extra instructions on it; help goes on a separate How-to / FAQ page (it gets a line in `PAGES` in `menu.js` on the day it is created). Every answer needs BM and English.

## "Location blocked" on iPhone (confirmed 9 Oct 2026)
- Cause: the link was opened inside WhatsApp's built-in browser, not in Safari. That browser blocks location even when Location and Safari are both on, and keeps blocking on later days.
- Evidence: one phone was blocked on two days from one browser and succeeded from another browser on the same phone (a different device ID). Three iPhone users were blocked on 9 Oct; the steps below fixed it the same morning.
- Fix:
  1. In WhatsApp, press and hold the link → Open in Safari.
  2. In Safari: Share → Add to Home Screen, and open it from that icon from now on.
  3. Still blocked: tap aA in the address bar → Website Settings → Location → Allow, then reload.
  4. Chrome on iPhone: Settings → Apps → Chrome → Location → While Using the App.
- Also check: Settings → Privacy & Security → Location Services → Safari Websites → While Using the App, Precise Location on.

## "Approximate location only" (Android, 7 Oct)
- Precise location is off for the browser: long-press Chrome → App info → Permissions → Location → Use precise location.

## "Location not found" / weak signal
- Indoors the phone may use Wi-Fi positioning. Step near a window or outdoors, wait for "Location found", then press Submit.

## "Outside the area"
- The check-in area is a circle around the check-in point, not the whole school. Walk towards the check-in point.

## "Already checked in"
- The first press was recorded; pressing again changes nothing.
- Check the event name before Submit: the page remembers the last event chosen (seen 9 Oct, when staff were trying two events).

## "Recorded, name not on the list"
- The event is for invited staff. The check-in is still recorded and the admin sees the mark.

## Late
- Late is counted from the accepted check-in, not the first attempt. Kept on purpose: a "location blocked" report carries no position and could be sent from home.

## General
- The staff code box is empty every time (example: MNHA); the code is not remembered on the phone.
- Light is automatic from 07:00 to 19:00 for reading outdoors.
- The thumbprint machine still applies during the pilot.

## Never in the FAQ
- That an event can have location switched off (maintainer's decision, 7 Oct 2026).
