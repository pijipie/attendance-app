# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

## Users

- **Staff** of Sek. Ren. Islam Al-Irsyad Balok, about 70 people (permanent staff plus a few interns and contract staff). They record their own attendance on their own device while physically at the location. Phones are the main device; tablets and computers must also work.
- **Two situations of equal weight:** daily attendance at school, and separate events and programmes (meetings, courses, off-site activities).
- **Admins** show the rotating QR at the location and read the attendance log. Who the admins are is an open decision (see below).
- **Maintainer:** one member of the school's staff who is not a professional programmer, can read code, and works through a browser with GitHub and Supabase.

## Product Purpose

Record who attended, where and when, with evidence, on a real database. It replaces the earlier Google Sheet and Apps Script system (v3, kept as a fallback) and the paper sign-in sheet.

The record serves three uses at once: the official attendance record, internal monitoring by management, and removal of the manual sheet. Because it is an official record, a wrong or missing entry has consequences for the person concerned.

Success means a staff member who is at the location can record attendance quickly on their own device, and a person who is not there cannot be recorded by someone else.

## Positioning

The database decides, not the page. The phone only reports measured facts (position, GPS accuracy, time, device, QR token) and one server function accepts or rejects them, keeping both outcomes as evidence. The anti-buddy-punching rule is "one device, one name, one event", backed by a rotating QR that can only be read at the location.

## Operating Context

- **Check-in flow:** open the page or scan the QR at the location, choose the event, enter the staff code, allow location access, submit, read the answer.
- **Conditions:** used on arrival, often outdoors or at an entrance, on mobile data, where GPS needs open sky. The accuracy limit is 30 m and geofence radii are 30 to 50 m.
- **Languages:** Bahasa Melayu by default, English through a small BM/EN button. The choice is remembered on the device.
- **Hosting:** static pages on GitHub Pages from a public repository; data on Supabase (PostgreSQL), free tier.
- **Time zone:** Asia/Kuala_Lumpur for "today" and for all time windows.

## Capabilities and Constraints

**Live now**

- Staff check-in page with event dropdown, BM/EN, and a typed-code fallback if the event list cannot be loaded.
- Server checks in this order: QR, time window, GPS accuracy, distance.
- One check-in per person per session per day; one person per device per session per day.

**Planned**

- Admin page: login, rotating QR screen, attendance log.
- Real time windows per event, both daily recurring and one-off dates. Today every window is "anytime".
- QR required per event through a per-event switch. Today it is off on every event.
- Later: linked-device binding, per-staff PIN, one-time passcodes.

**Decided against**

- A shared-device report.

**Constraints**

- Plain HTML, CSS and JavaScript with no build step.
- Free service tiers for now; a paid plan may come later for automation.
- Public repository: never commit staff names, CSV exports, venue coordinates or any secret key.
- The public key has no direct table access. Everything goes through database functions, and execute rights are granted on purpose.
- One person may own several devices.

**Terms used in the interface**

| Bahasa Melayu | English |
|---|---|
| Acara | Event |
| Kod staf | Staff code |
| Hantar kehadiran | Submit attendance |
| Kehadiran direkodkan | Attendance recorded |
| Di luar kawasan | Outside the area |
| Di luar waktu kehadiran | Outside attendance hours |

**Open decisions**

- Who the admins are (one person or several).
- Which device shows the rotating QR (large screen, tablet or phone).
- Whether refused duplicate and "device already used" attempts should leave a rejected row. Today they leave none.
- Whether the school's official colours must be used.
- Whether a formal accessibility standard applies.

## Brand Commitments

- The school is named on the page as "Sek. Ren. Islam Al-Irsyad Balok".
- Interface text exists in both Bahasa Melayu and English, with Bahasa Melayu first.
- The school logo appears in the page header and as the browser tab icon, from a single `logo.png` beside the page.
- No colour or typeface has been made binding.

## Evidence on Hand

- Live staff page: https://pijipie.github.io/attendance-app/
- Source: `index.html`, `database/01_schema.sql`, `database/02_after_import.sql`, `database/03_list_events.sql`.
- A working database with the real staff list and six real events, plus test rows that must be removed before the pilot.
- One real phone test on 3 Oct 2026: one accepted check-in at 7 m, one rejected at 7,825 m.
- There are no usage figures, user feedback, testimonials or screenshots from real use yet. Do not invent any.

## Product Principles

1. The server decides. The page reports facts and shows the answer.
2. Presence is proven, not claimed.
3. Every answer says what happened and what to do next, in the person's language.
4. One non-specialist must be able to maintain it with a browser and free services.
5. Personal data stays out of the public repository and out of the public interface.

## Accessibility & Inclusion

- Must work on phone, tablet and computer.
- Must be usable in Bahasa Melayu and in English.
- No formal standard has been set.
