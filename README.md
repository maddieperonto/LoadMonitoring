# UF S&C Dashboard

A real-time sport science dashboard for the University of Florida Division I Football
Strength & Conditioning staff. Built on Supabase (database + hosting) and GitHub (code).

---

## What This System Does

| Page | Who Can Access | Purpose |
|---|---|---|
| `index.html` | Head Coach, S&C Staff | Command Center — KPIs, flags, squad heatmap |
| `load_management.html` | S&C Staff | GPS load, ACWR, monotony, strain, RPE entry |
| `cmj.html` | S&C Staff | ForceDeck CMJ readiness, trends, asymmetry |
| `nordbord.html` | S&C Staff, Athletic Trainer | Hamstring symmetry, RTP tracker |
| `injury_risk.html` | S&C Staff, Athletic Trainer | Composite risk ranking, drill-down |
| `roster.html` | S&C Staff, Athletic Trainer | Athlete profiles, full history modal |
| `login.html` | Everyone | Supabase Auth login |

---

## File Structure

```
uf-sc-dashboard/
├── pages/
│   ├── index.html
│   ├── load_management.html
│   ├── cmj.html
│   ├── nordbord.html
│   ├── injury_risk.html
│   ├── roster.html
│   └── login.html
├── scripts/
│   ├── supabase_client.js       ← Supabase connection (edit your credentials here)
│   ├── auth.js                  ← Session checking, navbar, role guards
│   ├── catapult_to_supabase.R   ← Run at go-live to import Catapult GPS exports
│   ├── forcedeck_to_supabase.R  ← Run at go-live to import ForceDeck CMJ exports
│   └── nordbord_to_supabase.R   ← Run at go-live to import NordBord exports
├── data-imports/                ← Create this folder; drop device CSVs here at go-live
│   ├── catapult/
│   ├── forcedeck/
│   └── nordbord/
├── seed_data.sql                ← Simulated data for demos (wipe before go-live)
├── README.md                    ← This file
└── DATA_SOURCES.md              ← Database schema reference
```

---

## Part 1 — Supabase Project Setup (One Time)

### 1.1 Create a Supabase Project

1. Go to [supabase.com](https://supabase.com) and sign in
2. Click **New Project**
3. Choose your organization, name the project `uf-sc-dashboard`
4. Set a strong database password (save it somewhere safe — you won't need it often)
5. Select region: **US East (N. Virginia)** — closest to Gainesville
6. Click **Create new project** and wait ~2 minutes for provisioning

---

### 1.2 Run the Database Seed Script

This creates all 6 tables, Row Level Security policies, and populates the database
with simulated data for 85 athletes.

1. In your Supabase project, click **SQL Editor** in the left sidebar
2. Click **New query**
3. Open `seed_data.sql` from your project folder
4. Select all the content (Ctrl+A / Cmd+A) and paste it into the editor
5. Click **Run** (or press Ctrl+Enter)
6. You should see: `Success. No rows returned`

**Verify it worked:**
- Click **Table Editor** in the left sidebar
- You should see 6 tables: `athletes`, `gps_sessions`, `cmj_tests`,
  `nordbord_tests`, `flags`, `profiles`
- Click `athletes` — you should see 85 rows

---

### 1.3 Get Your API Credentials

1. Click **Project Settings** (gear icon) in the left sidebar
2. Click **API**
3. Copy two values:
   - **Project URL** — looks like `https://xxxxxxxxxxxx.supabase.co`
   - **anon public** key — a long JWT string starting with `eyJ...`

4. Open `scripts/supabase_client.js` in VS Code and replace the placeholders:

```js
const SUPABASE_URL      = 'https://xxxxxxxxxxxx.supabase.co';   // ← paste here
const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6Ikp...'; // ← paste here
```

---

## Part 2 — Create Test User Accounts (One Time)

The dashboard uses Supabase Auth for login. You need to create user accounts manually
in the Supabase dashboard, then link them to roles in the `profiles` table.

### 2.1 Create Users in Supabase Auth

1. In your Supabase project, click **Authentication** in the left sidebar
2. Click **Users**
3. Click **Add user** → **Create new user**
4. Create three accounts:

| Email | Password | Role |
|---|---|---|
| `coach@ufl.edu` | `UFCoach2025!` | head_coach |
| `scstaff@ufl.edu` | `UFStrength2025!` | sc_staff |
| `trainer@ufl.edu` | `UFTrainer2025!` | athletic_trainer |

> **Note:** These are demo credentials. For real staff accounts use proper
> passwords and real email addresses. Staff can reset their own passwords
> via Supabase Auth if needed.

### 2.2 Get the UUIDs

After creating each user:
1. Click on the user's row in the Auth → Users table
2. Copy the **UUID** shown at the top (looks like `a1b2c3d4-e5f6-...`)
3. Repeat for all three users

### 2.3 Insert Profiles with Roles

1. Go to **SQL Editor** → **New query**
2. Paste this SQL, replacing the UUIDs with the ones you just copied:

```sql
INSERT INTO public.profiles (id, full_name, role) VALUES
  ('paste-coach-uuid-here',   'Coach Billy Napier',  'head_coach'),
  ('paste-scstaff-uuid-here', 'Dr. Sarah Mitchell',  'sc_staff'),
  ('paste-trainer-uuid-here', 'Marcus Thompson ATC', 'athletic_trainer');
```

3. Click **Run**
4. Verify: click **Table Editor** → `profiles` — you should see 3 rows

---

## Part 3 — Local Testing with VS Code Live Server

You do not need to deploy anything to test the dashboard. Use VS Code's
Live Server extension to run everything locally against your live Supabase project.

### 3.1 Install Live Server

1. Open VS Code
2. Click the Extensions icon (or press Ctrl+Shift+X)
3. Search for **Live Server** by Ritwick Dey
4. Click Install

### 3.2 Run the Dashboard

1. Open your `uf-sc-dashboard` folder in VS Code:
   - File → Open Folder → select `uf-sc-dashboard`
2. Right-click `pages/login.html` in the Explorer panel
3. Click **Open with Live Server**
4. Your browser opens at `http://127.0.0.1:5500/pages/login.html`
5. Log in with `scstaff@ufl.edu` / `UFStrength2025!`

> **Why Live Server?** Opening HTML files directly (double-clicking them)
> uses the `file://` protocol which blocks ES module imports. Live Server
> runs a local HTTP server so JavaScript modules load correctly.

---

## Part 4 — Deploy to Supabase Storage (Go Live)

When you're ready to make the dashboard accessible to coaches without
VS Code, host the HTML files in Supabase Storage.

### 4.1 Create a Storage Bucket

1. In Supabase, click **Storage** in the left sidebar
2. Click **New bucket**
3. Name it: `dashboard`
4. Check **Public bucket** (so files are accessible via URL)
5. Click **Save**

### 4.2 Upload HTML and JS Files

Upload these files maintaining the folder structure:

```
pages/login.html
pages/index.html
pages/load_management.html
pages/cmj.html
pages/nordbord.html
pages/injury_risk.html
pages/roster.html
scripts/supabase_client.js
scripts/auth.js
```

**To upload:**
1. Click into the `dashboard` bucket
2. Create a `pages` folder: click **New folder** → type `pages`
3. Click into `pages`, then **Upload files** → select all HTML files
4. Go back to bucket root, create a `scripts` folder
5. Upload `supabase_client.js` and `auth.js` into `scripts`

### 4.3 Get the Public URL

1. Click on any uploaded file
2. Click **Get URL** — it will look like:
   `https://xxxxxxxxxxxx.supabase.co/storage/v1/object/public/dashboard/pages/login.html`
3. Share the `login.html` URL with your staff — that's their entry point

> **Important:** After uploading to Storage, the path references in `auth.js`
> (`/pages/`, `/scripts/`) may need to become full Supabase Storage URLs.
> The simplest fix is to use relative paths (`../scripts/supabase_client.js`)
> which work correctly in both Live Server and Supabase Storage.

---

## Part 5 — GitHub Integration (After Go-Live)

Link GitHub to auto-deploy file changes to Supabase Storage instead of
uploading manually every time.

### 5.1 When to Do This

Set this up after you have confirmed the dashboard works end-to-end in
Supabase Storage. Do not set it up during the testing phase.

### 5.2 GitHub Action for Auto-Deploy

Create this file in your repo: `.github/workflows/deploy.yml`

```yaml
name: Deploy to Supabase Storage

on:
  push:
    branches: [main]
    paths:
      - 'pages/**'
      - 'scripts/supabase_client.js'
      - 'scripts/auth.js'

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Install Supabase CLI
        run: npm install -g supabase

      - name: Upload pages to Storage
        env:
          SUPABASE_ACCESS_TOKEN: ${{ secrets.SUPABASE_ACCESS_TOKEN }}
          SUPABASE_PROJECT_ID:   ${{ secrets.SUPABASE_PROJECT_ID }}
        run: |
          supabase storage cp pages/ ss:///dashboard/pages/ \
            --project-ref $SUPABASE_PROJECT_ID --recursive
          supabase storage cp scripts/supabase_client.js ss:///dashboard/scripts/ \
            --project-ref $SUPABASE_PROJECT_ID
          supabase storage cp scripts/auth.js ss:///dashboard/scripts/ \
            --project-ref $SUPABASE_PROJECT_ID
```

Add these GitHub repository secrets (Settings → Secrets → Actions):
- `SUPABASE_ACCESS_TOKEN` — from Supabase Account Settings → Access Tokens
- `SUPABASE_PROJECT_ID` — the short ID from your Supabase project URL

After this is set up, every `git push` to `main` automatically updates
the live dashboard.

---

## Part 6 — Going Live with Real Data

When you are ready to replace simulated data with real device exports:

### 6.1 Wipe the Simulated Data

Run this in the Supabase SQL Editor:

```sql
-- Remove all simulated data (keeps table structure and RLS policies intact)
TRUNCATE flags, nordbord_tests, cmj_tests, gps_sessions, athletes CASCADE;
```

> **Warning:** This permanently deletes all current data. Only run this
> when you are ready to switch to real data.

### 6.2 Add Your Real Roster

Option A — Supabase Table Editor (recommended for first import):
1. Go to Table Editor → `athletes`
2. Click **Insert row** for each athlete
3. Fill in: name, jersey_number, position, class_year, height_in, weight_lbs, status

Option B — Create a roster CSV and use an R script similar to the device
import scripts to bulk insert (see DATA_SOURCES.md for the column format).

### 6.3 Run the R Import Scripts

After each practice or testing session:

1. Export CSV from your device software
2. Drop the file into the appropriate `data-imports/` subfolder
3. Open the matching R script in RStudio
4. Update the `CSV_PATH` to point to your new file
5. Run with `DRY_RUN <- TRUE` first — review the console output
6. Set `DRY_RUN <- FALSE` and run again to insert

See the comments at the top of each R script for device-specific export
instructions.

### 6.4 Install R Packages (One Time)

Run this in the RStudio console before using any import script:

```r
install.packages(c("httr2", "readr", "dplyr", "stringr", "lubridate"))
```

---

## Role Permissions Reference

| Feature | head_coach | sc_staff | athletic_trainer |
|---|---|---|---|
| Command Center (`index.html`) | ✅ | ✅ | ❌ |
| Load Management | ❌ | ✅ | ❌ |
| CMJ Data | ❌ | ✅ | ❌ |
| NordBord | ❌ | ✅ | ✅ |
| Injury Risk | ❌ | ✅ | ✅ |
| Roster | ❌ | ✅ | ✅ |
| CSV Export buttons | ❌ | ✅ | ❌ |
| RPE Entry | ❌ | ✅ | ❌ |

---

## Troubleshooting

**Login does nothing / page goes blank**
- You are opening the HTML file directly (double-click). Use Live Server instead.
- Check browser console (F12) for errors.

**"Failed to load data" error on any page**
- Open `scripts/supabase_client.js` and verify your URL and anon key are correct.
- Go to Supabase → Authentication → Policies and confirm RLS policies exist on all tables.

**Athletes not matching in R scripts**
- Check for spelling differences between the device export and the `athletes` table.
- The scripts print unmatched names to the console — fix the spelling in one place.

**Charts not rendering**
- Check browser console for JavaScript errors.
- Confirm Chart.js CDN loaded (requires internet connection).

**Auth redirect loops**
- Clear browser cookies and local storage for `127.0.0.1`.
- In Supabase → Authentication → URL Configuration, add `http://127.0.0.1:5500`
  to the allowed redirect URLs list.

---

## Technology Stack

| Layer | Technology |
|---|---|
| Database | Supabase Postgres |
| Auth | Supabase Auth (email/password) |
| Hosting | Supabase Storage (or local via Live Server) |
| Frontend | Vanilla HTML + CSS + JavaScript (ES Modules) |
| Charts | Chart.js 4.4 via CDN |
| Icons | Lucide Icons via CDN |
| Fonts | Google Fonts (Inter, Barlow Condensed) |
| Data pipeline | R (httr2, readr, dplyr) |
| Code editor | VS Code + Live Server extension |

---

## Key Contacts / Ownership

| Role | Responsibility |
|---|---|
| S&C Staff | Daily data exports, RPE entry, flag review |
| Athletic Trainer | NordBord testing, RTP monitoring |
| Dashboard Admin | User account management, R script execution |
| Developer | Code changes, Supabase schema updates |

---

*UF Football Strength & Conditioning — Internal Use Only*
*Data source documentation: see DATA_SOURCES.md*
