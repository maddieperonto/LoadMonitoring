# UF Football S&C Load Monitoring Dashboard

A real-time sport science dashboard for the University of Florida Football
Strength & Conditioning staff, tracking GPS load (Catapult), force plate/strength
testing (VALD), and derived metrics (ACWR, load ramp-up, leaderboards, session
comparisons, period/drill breakdowns) for the full roster.

> **Note:** An earlier version of this README described a different, planned
> architecture (Supabase Storage hosting, R "go-live" import scripts, role-based
> auth). That plan was superseded by what's documented below — this file now
> reflects the system as it actually runs in production.

---

## Live System

- **Dashboard**: deployed via Vercel, auto-deploys from `main` on every push
- **Staff view**: `pages/dashboard.html`
- **Athlete-facing view**: `pages/athlete.html`

---

## Architecture

| Layer | Technology |
|---|---|
| Frontend | Single-file vanilla HTML/CSS/JS per page, no build step |
| Charts | Chart.js 4.4 via CDN |
| Hosting | Vercel, auto-deploy from GitHub `main` branch |
| Database | Supabase Postgres |
| Backend logic | Supabase Edge Functions (Deno/TypeScript) + `pg_cron` scheduling |
| GPS pipeline | Catapult OpenField → webhook → Supabase Edge Function |
| Force/strength pipeline | VALD ForceDecks/NordBord → nightly R script via GitHub Actions |
| Auth | Username-based login via Supabase (not Supabase's role-based auth system) |

---

## File Structure

```
LoadMonitoring/
├── pages/
│   ├── dashboard.html      ← Main staff dashboard (single large file: HTML+CSS+JS)
│   └── athlete.html        ← Athlete-facing login/view
├── scripts/
│   ├── vald_sync.R                    ← Nightly VALD sync (runs via GitHub Actions)
│   ├── vald_backfill_metrics.R        ← One-off historical VALD metric backfill
│   └── create_athletes.mjs            ← Admin script for creating athlete accounts
├── .github/workflows/
│   └── vald-sync.yml       ← Nightly cron trigger for vald_sync.R
└── README.md                ← This file
```

**Note:** Supabase Edge Functions (the Catapult integration) live in the Supabase
dashboard under Edge Functions — they are **not** stored in this GitHub repo.
See "Supabase Edge Functions" below for what exists and what each one does.

---

## Supabase Edge Functions

These are managed directly in the Supabase dashboard (Project → Edge Functions), not in Git.

| Function | Purpose | Trigger |
|---|---|---|
| `catapult-webhook` | **Core GPS sync.** Fires on every Catapult activity update. Writes to `catapult_sessions` and `catapult_period_stats`. Captures participation tags. Filters out Catapult's auto-created junk activities (named `Activity <digits>`). | Catapult webhook subscription |
| `catapult-athlete-profiles-sync` | Pulls each athlete's profile max velocity from Catapult `/athletes`, writes to `athletes.max_velocity_mph` and `athletes.catapult_athlete_id`. | `pg_cron`, nightly |
| `catapult-diagnostic` | Debug/inspection tool for testing Catapult API responses directly. Not part of the live pipeline. | Manual only |
| `catapult-sessions-recheck` | Re-pulls fresh stats for existing activities into a separate comparison table (`catapult_sessions_recheck`), used to catch/diagnose sessions that synced with incomplete data. | Manual only |
| `catapult-period-backfill` | One-time historical backfill of `catapult_period_stats`. Already run. | Manual only |
| `catapult-tag-backfill` | One-time historical backfill of `catapult_sessions.participation_tag`. Already run. | Manual only |

To check `pg_cron` job status/history:
```sql
select * from cron.job;
select * from cron.job_run_details order by start_time desc limit 10;
```

---

## Key Database Tables

| Table | Contents |
|---|---|
| `athletes` | Roster. Includes `catapult_athlete_id`, `max_velocity_mph` (synced nightly) |
| `catapult_sessions` | GPS session totals per athlete per activity. Includes `participation_tag` (e.g. `'Full'`, `'Rehab'`) |
| `catapult_period_stats` | Per-athlete, per-drill/period breakdown within each practice session |
| `cmj_tests` | VALD ForceDecks CMJ jump testing data |
| `nordbord_tests` | VALD NordBord hamstring testing data |
| `catapult_sessions_recheck` | One-time comparison table, not used by the live dashboard |

**Important:** `session_date` is stored as **text** (`MM/DD/YYYY`), not a real date
column. Any SQL sorting/filtering by date must use `to_date(session_date, 'MM/DD/YYYY')`
or it will sort alphabetically instead of chronologically.

---

## Secrets / Environment Variables

Secrets live in **two separate places** and must be kept in sync manually — there is
no automatic sharing between them:

1. **GitHub** (Settings → Secrets and variables → Actions) — used by `vald-sync.yml`
2. **Supabase** (Project Settings → Edge Functions → Secrets) — used by all Edge Functions

| Secret | Used by | Notes |
|---|---|---|
| `CATAPULT_BASE_URL` | Edge Functions | e.g. `https://connect-us.catapultsports.com/api/v6` |
| `CATAPULT_API_TOKEN` | Edge Functions | Generated in OpenField Cloud → Settings → API Tokens. Must have full scope (Summary Data, Sensor Data, Activities, Athletes, Tags, etc.) |
| `VALD_CLIENT_ID` / `VALD_CLIENT_PASSWORD` / `VALD_DUENDE_ID` | GitHub Actions (`vald_sync.R`) | OAuth client credentials for VALD's API |
| `SUPABASE_URL` / `SUPABASE_SERVICE_ROLE_KEY` | Edge Functions | Server-side Supabase access |
| `SUPABASE_URL` / `SUPABASE_SERVICE_KEY` | GitHub Actions | Same purpose, different secret store |

**Secret values cannot be viewed again once saved** — only rotated. If a token needs
regenerating, it must be recreated from scratch with the provider (Catapult/VALD) and
updated in both places above.

---

## Known Quirks & Gotchas

1. **GitHub Actions cannot successfully call Catapult's `/athletes` endpoint** — it
   returns a persistent 401 even with a correct token, likely due to IP allowlisting
   on Catapult's side. Supabase Edge Functions work fine for the identical call. Any
   new Catapult integration should be built as a Supabase Edge Function, not a GitHub
   Actions/R script.

2. **Catapult's `velocity_max` field (profile max velocity) is returned in meters/second**,
   not mph. Multiply by `2.23694` to match what OpenField's own UI shows.

3. **Catapult sometimes auto-creates junk "activities"** (default name pattern:
   `Activity <digits>`) when a unit is powered on but not assigned to a tracked
   period. `catapult-webhook` filters these out by name pattern before syncing —
   if this starts happening under a different naming convention, the filter in
   `catapult-webhook` will need updating.

4. **Catapult webhook events can fire multiple times per activity** as stats get
   recalculated, but can also **stop firing before a session finishes processing**,
   leaving partial/incomplete data synced. There's no automatic re-check for this —
   `catapult-sessions-recheck` exists as a manual tool to re-pull and compare if
   numbers look wrong for a specific date.

5. **Athlete names differ across systems** (Catapult, VALD, the `athletes` table) —
   e.g. "Ace Ciongoli" in Catapult = "Austin Ciongoli" in Supabase. Every sync script
   has a `NAME_MAP` object handling known mismatches. When a name doesn't match, it
   logs as "unmatched" — check sync logs periodically, especially after roster changes,
   and add new mappings as needed.

6. **Participation tags**: athletes tagged `Rehab` in Catapult's Activity Editor are
   captured into `catapult_sessions.participation_tag`. Load Monitor and Session
   Compare pages exclude `Rehab`-tagged rows from averages to match what Catapult's
   own reports show.

7. **New tables need explicit Row Level Security (RLS) policies**, or the dashboard's
   anon key silently returns zero rows (no error thrown). Copy this pattern for any
   new table:
   ```sql
   alter table [new_table] enable row level security;
   create policy "Service role full access" on [new_table] for all using (true);
   create policy "Authenticated users can read [new_table]" on [new_table] for select using (true);
   ```

8. **Supabase queries cap at 1000 rows by default.** Scripts/functions pulling large
   tables must paginate with `.range()` or will silently undercount.

9. **Vercel's auto-deploy from GitHub occasionally fails silently** with no new
   deployment triggered. Fix: `git commit --allow-empty -m "Trigger Vercel redeploy" && git push`.

10. **`GPS_ROSTER`** — a hardcoded JS array inside `dashboard.html` — controls which
    athletes appear in GPS-related views. This needs manual updates when the roster
    changes; it does not automatically sync from the `athletes` table.

---

## Local Development / Testing

No build step or bundler — these are static files. To test locally with a live
connection to the real Supabase project:

```bash
cd pages
python3 -m http.server 8000
```

Then open `http://localhost:8000/dashboard.html` in your browser. Edits to the file
take effect on refresh — no server restart needed. Push to `main` when ready to deploy.

---

## Ongoing Maintenance

- **When the roster changes**: update `GPS_ROSTER` in `dashboard.html`, and check
  `NAME_MAP` objects in `vald_sync.R` and the `catapult-athlete-profiles-sync` Edge
  Function for new name mismatches.
- **Check sync logs periodically** (Supabase Edge Function logs, GitHub Actions run
  history) for unmatched-name warnings or failed syncs.
- **Catapult API tokens may expire** — check OpenField Cloud → Settings → API Tokens.

---

## Support Contacts

- **Catapult support**: prior ticket history with Amber Miller / Alahna Mild / Aaron
  Catapult Sports support — useful reference for the `/athletes` 401 issue and any
  future account-level module/scope questions.
- **VALD support**: contact via VALD's standard support channel.

---

*University of Florida Football Strength & Conditioning — Internal Use Only*