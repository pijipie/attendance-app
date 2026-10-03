# Attendance App

Geo-fenced staff attendance (Supabase + static pages on GitHub Pages).

- `index.html` — staff check-in page (phone / tablet / desktop, BM / EN)
- `database/` — SQL that builds the Supabase database. Run in order in Supabase > SQL Editor:
  1. `01_schema.sql` — tables, security and functions
  2. `02_after_import.sql` — after importing the staff and event CSVs
  3. `03_list_events.sql` — `list_events()` for the staff page's event dropdown

> **Do NOT commit staff names, CSV exports or any secret/service_role key to this public repo.**
